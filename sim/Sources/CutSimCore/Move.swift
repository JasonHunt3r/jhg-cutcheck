import Foundation

/// One commanded motion, with absolute start and end in millimetres.
public struct Move: Sendable {
    public enum Kind: String, Sendable {
        case rapid, linear, arcCW, arcCCW

        public var isArc: Bool { self == .arcCW || self == .arcCCW }
    }

    public let lineNo: Int
    public let kind: Kind
    public let start: SIMD3<Double>
    public let end: SIMD3<Double>
    /// XY centre, arcs only.
    public let center: SIMD2<Double>?
    public let feed: Double?
    public let spindle: Double?
    /// Index into `Program.sections`, or nil before the first section header.
    public let section: Int?

    public var isRapid: Bool { kind == .rapid }
    public var isArc: Bool { kind.isArc }
    public var dz: Double { end.z - start.z }
    public var minZ: Double { min(start.z, end.z) }

    public var radius: Double? {
        guard let c = center else { return nil }
        return (SIMD2(start.x, start.y) - c).length
    }

    /// Signed swept angle in radians; zero for non-arcs.
    public var sweep: Double {
        guard let c = center else { return 0 }
        let a0 = atan2(start.y - c.y, start.x - c.x)
        let a1 = atan2(end.y - c.y, end.x - c.x)
        var d = a1 - a0
        if kind == .arcCW {
            while d >= 0 { d -= 2 * .pi }
            while d < -2 * .pi { d += 2 * .pi }
            if abs(d) < 1e-9 { d = -2 * .pi }   // coincident ends = full circle
        } else {
            while d <= 0 { d += 2 * .pi }
            while d > 2 * .pi { d -= 2 * .pi }
            if abs(d) < 1e-9 { d = 2 * .pi }
        }
        return d
    }

    /// Path length in XY, following the arc rather than the chord.
    public var xyLength: Double {
        if isArc { return abs(sweep) * (radius ?? 0) }
        return (SIMD2(end.x, end.y) - SIMD2(start.x, start.y)).length
    }

    public var length: Double { (SIMD2(xyLength, dz)).length }

    /// Absolute points approximating this move, endpoints included.
    /// Arcs subdivide so the chord never departs from the true arc by more
    /// than `maxSag`.
    public func polyline(maxSag: Double = 0.005) -> [SIMD3<Double>] {
        guard isArc, let c = center else { return [start, end] }
        let r = radius ?? 0
        guard r > 0 else { return [start, end] }

        let sweep = self.sweep
        let step = maxSag >= r ? abs(sweep) : 2 * acos(1 - maxSag / r)
        let n = max(2, Int(ceil(abs(sweep) / max(step, 1e-9))))

        let a0 = atan2(start.y - c.y, start.x - c.x)
        var pts = [SIMD3<Double>]()
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let t = Double(i) / Double(n)
            let a = a0 + sweep * t
            pts.append(SIMD3(c.x + r * cos(a),
                             c.y + r * sin(a),
                             start.z + (end.z - start.z) * t))
        }
        pts[pts.count - 1] = end   // land exactly on the commanded endpoint
        return pts
    }
}

extension SIMD2 where Scalar == Double {
    var length: Double { (x * x + y * y).squareRoot() }
}
