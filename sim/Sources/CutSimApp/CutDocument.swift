import Foundation
import CutSimCore
import Observation

/// One loaded NC file: its program, the stock it cuts, and the machinery
/// for showing the block at any moment in the program.
///
/// Scrubbing does not store every frame. Keyframes are kept at intervals
/// and any moment is reached by restoring the nearest earlier keyframe and
/// replaying forward, which keeps memory flat and backward jumps cheap.
@Observable
@MainActor
final class CutDocument {

    struct Landmark: Identifiable {
        let id: Int
        let name: String
        let firstMove: Int
        /// Short label for a button, e.g. "ROUGH: BODY OUTLINE" -> "Rough"
        var short: String {
            let head = name.split(separator: ":").first.map(String.init) ?? name
            return head.capitalized
        }
    }

    private(set) var url: URL?
    private(set) var program = Program()
    private(set) var field: HeightField?
    private(set) var landmarks: [Landmark] = []
    private(set) var status = "No file open"
    private(set) var busy = false
    var wireframe = false

    var moveCount: Int { program.moves.count }
    var currentMove: Int = 0

    private var keyframes: [(index: Int, heights: [Float])] = []
    private var radius: Double = 3.175

    /// Grid cell size. Every cut wall is quantised to this, so it is the
    /// single biggest lever on how smooth the result looks.
    enum Quality: Double, CaseIterable, Identifiable {
        case coarse = 0.6
        case fine = 0.3
        case finer = 0.2
        case finest = 0.12

        public var id: Double { rawValue }
        var label: String {
            switch self {
            case .coarse: return "Coarse"
            case .fine:   return "Fine"
            case .finer:  return "Finer"
            case .finest: return "Finest"
            }
        }
        var detail: String { String(format: "%.2fmm", rawValue) }
    }

    var quality: Quality = .fine {
        didSet { if quality != oldValue { reload() } }
    }
    private var resolution: Double { quality.rawValue }

    /// Keyframes are full copies of the grid, so their count has to fall as
    /// the grid gets finer or a fine setting would eat gigabytes.
    private static let keyframeBudgetBytes = 192 << 20

    // MARK: - loading

    func open(url: URL, restoringMove: Int? = nil) {
        busy = true
        defer { busy = false }
        do {
            var prog = try NCParser.parse(path: url.path)
            prog.source = url.path
            guard !prog.moves.isEmpty else { status = "No moves in \(url.lastPathComponent)"; return }

            self.url = url
            self.program = prog
            self.radius = prog.bitRadius ?? 3.175

            var loX = Double.greatestFiniteMagnitude, loY = Double.greatestFiniteMagnitude
            var hiX = -Double.greatestFiniteMagnitude, hiY = -Double.greatestFiniteMagnitude
            var zlo = 0.0
            for m in prog.moves {
                loX = min(loX, m.start.x, m.end.x); hiX = max(hiX, m.start.x, m.end.x)
                loY = min(loY, m.start.y, m.end.y); hiY = max(hiY, m.start.y, m.end.y)
                zlo = min(zlo, m.minZ)
            }
            let margin = 5.0
            let thickness = prog.depthTotal ?? abs(zlo)

            let f = HeightField(xmin: loX - margin, xmax: hiX + margin,
                                ymin: loY - margin, ymax: hiY + margin,
                                top: 0, bottom: -thickness, resolution: resolution)
            self.field = f

            landmarks = prog.sections.enumerated().compactMap { i, s in
                // Sections with no motion (PARAMETERS, MACHINE SETUP) are not
                // places you can stand.
                guard s.lastMove > s.firstMove else { return nil }
                return Landmark(id: i, name: s.name, firstMove: s.firstMove)
            }

            buildKeyframes()
            let target = min(restoringMove ?? (prog.moves.count - 1), prog.moves.count - 1)
            currentMove = target
            seek(to: target)
            status = "\(url.lastPathComponent) — \(prog.moves.count) moves, "
                + "\(landmarks.count) sections, \(f.nx)x\(f.ny) @ \(quality.detail)"
        } catch {
            status = "Could not read \(url.lastPathComponent)"
        }
    }

    /// Re-run at the current quality, holding position in the program.
    private func reload() {
        guard let u = url else { return }
        let keepMove = currentMove
        open(url: u, restoringMove: keepMove)
    }

    private func buildKeyframes() {
        guard let f = field else { return }
        keyframes.removeAll()
        let n = program.moves.count
        guard n > 0 else { return }

        let gridBytes = f.nx * f.ny * MemoryLayout<Float>.size
        let affordable = max(2, min(24, Self.keyframeBudgetBytes / max(gridBytes, 1)))
        let stride = max(1, n / affordable)

        // Reset, then walk forward recording snapshots.
        let fresh = HeightField(xmin: f.xmin, xmax: f.xmax, ymin: f.ymin, ymax: f.ymax,
                                top: f.top, bottom: f.bottom, resolution: f.resolution)
        keyframes.append((index: -1, heights: fresh.h))
        var i = 0
        while i < n {
            let upto = min(i + stride - 1, n - 1)
            Simulator.run(program: program, into: fresh, radius: radius,
                          from: i, through: upto)
            keyframes.append((index: upto, heights: fresh.h))
            i = upto + 1
        }
    }

    /// Show the block as it stands after `move` has been executed.
    func seek(to move: Int) {
        guard let f = field, !program.moves.isEmpty else { return }
        let target = max(-1, min(move, program.moves.count - 1))
        currentMove = max(0, target)

        var base = keyframes.first!
        for k in keyframes where k.index <= target { base = k }
        f.replace(heights: base.heights)
        if base.index < target {
            Simulator.run(program: program, into: f, radius: radius,
                          from: base.index + 1, through: target)
        }
        generation &+= 1
    }

    /// Bumped whenever the height data changes, so the view knows to re-upload.
    private(set) var generation: UInt64 = 0

    var currentSectionName: String {
        guard currentMove < program.moves.count,
              let s = program.moves[currentMove].section,
              s < program.sections.count else { return "—" }
        return program.sections[s].name
    }
}
