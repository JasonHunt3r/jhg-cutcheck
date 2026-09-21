import Foundation

public struct ParseWarning: Sendable {
    public let lineNo: Int
    public let code: String
    public let detail: String
}

/// A named span of the program, taken from the generator's own
/// `; SECTION:` comments. These are the landmarks a viewer jumps between.
public struct Section: Sendable {
    public let name: String
    public let lineNo: Int
    public var firstMove: Int
    public var lastMove: Int
    /// Distinct cut depths seen inside this section, in the order the
    /// `; --- Z=... ---` markers appear.
    public var depths: [Double]
}

public struct Program: Sendable {
    public init() {}

    public var moves: [Move] = []
    public var sections: [Section] = []
    public var warnings: [ParseWarning] = []
    public var units: String = "mm"
    public var source: String = ""
    /// Key/value pairs from the header block, e.g. "BIT_R" -> "3.175mm".
    public var header: [String: String] = [:]

    /// Tool radius in mm if the header declares BIT_R.
    public var bitRadius: Double? { Self.leadingNumber(header["BIT_R"]) }
    public var depthTotal: Double? { Self.leadingNumber(header["DEPTH_TOTAL"]) }
    public var safeZ: Double? { Self.leadingNumber(header["SAFE_Z"]) }

    static func leadingNumber(_ s: String?) -> Double? {
        guard let s else { return nil }
        var digits = ""
        for ch in s {
            if ch.isNumber || ch == "." || (digits.isEmpty && ch == "-") {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}

/// Arc endpoint radii must agree to this, in mm, or the arc is malformed.
/// Stricter than GRBL's own tolerance on purpose.
public let arcRadiusTolerance = 0.002

public enum NCParser {

    public static func parse(path: String) throws -> Program {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var prog = parse(text: text)
        prog.source = path
        return prog
    }

    public static func parse(text: String) -> Program {
        var prog = Program()
        var x = 0.0, y = 0.0, z = 0.0
        var feed: Double? = nil
        var spindle: Double? = nil
        var motion: Move.Kind? = nil
        var absolute = true
        var unitScale = 1.0
        var seenUnknown = Set<String>()
        var currentSection: Int? = nil

        var lineNo = 0
        text.enumerateLines { rawLine, _ in
            lineNo += 1
            let raw = rawLine

            // Comment text carries the landmarks, so read it before stripping.
            if let semi = raw.firstIndex(of: ";") {
                let comment = raw[raw.index(after: semi)...]
                    .trimmingCharacters(in: .whitespaces)
                if comment.hasPrefix("SECTION:") {
                    let name = comment.dropFirst("SECTION:".count)
                        .trimmingCharacters(in: .whitespaces)
                    prog.sections.append(Section(name: name, lineNo: lineNo,
                                                 firstMove: prog.moves.count,
                                                 lastMove: prog.moves.count,
                                                 depths: []))
                    currentSection = prog.sections.count - 1
                } else if comment.hasPrefix("---"), comment.contains("Z=") {
                    if let r = comment.range(of: "Z="),
                       let v = Program.leadingNumber(String(comment[r.upperBound...])),
                       let s = currentSection, !prog.sections[s].depths.contains(v) {
                        prog.sections[s].depths.append(v)
                    }
                } else if let colon = comment.firstIndex(of: ":") {
                    let k = String(comment[..<colon]).trimmingCharacters(in: .whitespaces)
                    let v = String(comment[comment.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty && !v.isEmpty && !k.contains(" ") {
                        prog.header[k] = v
                    }
                }
            }

            // Strip comments: ";" to end of line, and "(...)" spans.
            var code = raw
            if let semi = code.firstIndex(of: ";") { code = String(code[..<semi]) }
            code = stripParens(code)
            if code.trimmingCharacters(in: .whitespaces).isEmpty { return }

            var axis: [Character: Double] = [:]
            var motionThisLine: Move.Kind? = nil

            for (letter, value) in words(in: code) {
                let v = value
                switch letter {
                case "G":
                    let g = Int((v).rounded())
                    switch g {
                    case 0: motionThisLine = .rapid
                    case 1: motionThisLine = .linear
                    case 2: motionThisLine = .arcCW
                    case 3: motionThisLine = .arcCCW
                    case 20:
                        unitScale = 25.4; prog.units = "in"
                        prog.warnings.append(.init(lineNo: lineNo, code: "units_inch",
                                                   detail: "G20: file is in inches"))
                    case 21: unitScale = 1.0; prog.units = "mm"
                    case 90: absolute = true
                    case 91:
                        absolute = false
                        prog.warnings.append(.init(lineNo: lineNo, code: "incremental",
                                                   detail: "G91 incremental mode"))
                    case 17: break
                    case 18, 19:
                        prog.warnings.append(.init(lineNo: lineNo, code: "plane",
                                                   detail: "G\(g): non-XY plane arcs"))
                    case 4, 28, 30, 53, 54, 80, 92, 93, 94: break
                    default:
                        let key = "G\(g)"
                        if seenUnknown.insert(key).inserted {
                            prog.warnings.append(.init(lineNo: lineNo, code: "unknown_code",
                                                       detail: "unhandled \(key)"))
                        }
                    }
                case "M": break
                case "F": feed = v * unitScale
                case "S": spindle = v
                case "X", "Y", "Z", "I", "J", "K", "R":
                    axis[letter] = v * unitScale
                default: break
                }
            }

            if let m = motionThisLine { motion = m }

            guard axis["X"] != nil || axis["Y"] != nil || axis["Z"] != nil else { return }
            guard let currentMotion = motion else {
                prog.warnings.append(.init(lineNo: lineNo, code: "no_motion_mode",
                                           detail: "coordinates before any G0-G3"))
                return
            }

            let sx = x, sy = y, sz = z
            if absolute {
                x = axis["X"] ?? x; y = axis["Y"] ?? y; z = axis["Z"] ?? z
            } else {
                x += axis["X"] ?? 0; y += axis["Y"] ?? 0; z += axis["Z"] ?? 0
            }

            var kind = currentMotion
            var center: SIMD2<Double>? = nil
            if currentMotion.isArc {
                center = arcCenter(prog: &prog, lineNo: lineNo,
                                   start: SIMD2(sx, sy), end: SIMD2(x, y),
                                   axis: axis, motion: currentMotion)
                if center == nil { kind = .linear }   // degenerate: straight move
            }

            prog.moves.append(Move(lineNo: lineNo, kind: kind,
                                   start: SIMD3(sx, sy, sz), end: SIMD3(x, y, z),
                                   center: center, feed: feed, spindle: spindle,
                                   section: currentSection))
            if let s = currentSection { prog.sections[s].lastMove = prog.moves.count - 1 }
        }

        return prog
    }

    // MARK: - scanning

    /// Scan "G1", "X-12.5", "I.003" style words without a regex engine.
    static func words(in s: String) -> [(Character, Double)] {
        var out: [(Character, Double)] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c.isLetter else { i += 1; continue }
            let letter = Character(c.uppercased())
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            var num = ""
            if j < chars.count, chars[j] == "-" { num.append("-"); j += 1 }
            var sawDigit = false
            while j < chars.count, chars[j].isNumber || chars[j] == "." {
                if chars[j].isNumber { sawDigit = true }
                num.append(chars[j]); j += 1
            }
            if sawDigit, let v = Double(num) { out.append((letter, v)) }
            i = max(j, i + 1)
        }
        return out
    }

    static func stripParens(_ s: String) -> String {
        guard s.contains("(") else { return s }
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1; out.append(" ") }
            else if ch == ")" { depth = max(0, depth - 1); out.append(" ") }
            else if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// Resolve an arc centre from I/J offsets or an R radius. GRBL treats
    /// I/J as incremental from the start point; R takes the minor arc when
    /// positive and the major arc when negative.
    static func arcCenter(prog: inout Program, lineNo: Int,
                          start: SIMD2<Double>, end: SIMD2<Double>,
                          axis: [Character: Double], motion: Move.Kind) -> SIMD2<Double>? {
        if axis["I"] != nil || axis["J"] != nil {
            let c = SIMD2(start.x + (axis["I"] ?? 0), start.y + (axis["J"] ?? 0))
            let rStart = (start - c).length
            let rEnd = (end - c).length
            if rStart < 1e-9 {
                prog.warnings.append(.init(lineNo: lineNo, code: "arc_zero_radius",
                                           detail: "arc centre equals start point"))
                return nil
            }
            if abs(rStart - rEnd) > arcRadiusTolerance {
                prog.warnings.append(.init(
                    lineNo: lineNo, code: "arc_radius_mismatch",
                    detail: String(format: "start r=%.4f end r=%.4f (delta %.4fmm)",
                                   rStart, rEnd, abs(rStart - rEnd))))
            }
            return c
        }

        if let r = axis["R"] {
            let d = (end - start).length
            if d < 1e-9 {
                prog.warnings.append(.init(lineNo: lineNo, code: "arc_r_full_circle",
                                           detail: "R-format arc with no travel"))
                return nil
            }
            let hSq = r * r - (d / 2) * (d / 2)
            if hSq < 0 {
                prog.warnings.append(.init(
                    lineNo: lineNo, code: "arc_radius_too_small",
                    detail: String(format: "R=%g cannot span %.4fmm", r, d)))
                return nil
            }
            let h = hSq.squareRoot()
            let mid = (start + end) / 2
            let u = SIMD2(-(end.y - start.y) / d, (end.x - start.x) / d)
            let sign: Double = ((r > 0) == (motion == .arcCCW)) ? 1 : -1
            return mid + u * (sign * h)
        }

        prog.warnings.append(.init(lineNo: lineNo, code: "arc_no_centre",
                                   detail: "arc with no I/J and no R"))
        return nil
    }
}
