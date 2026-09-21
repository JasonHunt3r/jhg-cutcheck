import Foundation

/// A rectangular block as a grid of surface heights.
///
/// Each cell holds the Z of the material surface in that column. Cutting
/// lowers cells; nothing ever raises them. Everything above a cell's height
/// has been removed, which is what lets the cutter's shaft be ignored --
/// only the tip's depth matters.
public final class HeightField {
    public let xmin, xmax, ymin, ymax: Double
    public let top, bottom: Double
    public let resolution: Double
    public let nx, ny: Int
    public internal(set) var h: [Float]

    public init(xmin: Double, xmax: Double, ymin: Double, ymax: Double,
                top: Double, bottom: Double, resolution: Double) {
        self.xmin = xmin; self.xmax = xmax
        self.ymin = ymin; self.ymax = ymax
        self.top = top; self.bottom = bottom
        self.resolution = resolution
        self.nx = Int(((xmax - xmin) / resolution).rounded(.up)) + 1
        self.ny = Int(((ymax - ymin) / resolution).rounded(.up)) + 1
        self.h = [Float](repeating: Float(top), count: nx * ny)
    }

    public var cellArea: Double { resolution * resolution }

    public func height(ix: Int, iy: Int) -> Float { h[iy * nx + ix] }

    public func removedVolume() -> Double {
        var acc = 0.0
        let t = Float(top)
        for v in h { acc += Double(t - v) }
        return acc * cellArea
    }

    public func lowest() -> Double { Double(h.min() ?? Float(top)) }

    /// Sweep the cutter from `p0` to `p1`, lowering every cell it covers.
    public func cutSegment(_ p0: SIMD3<Double>, _ p1: SIMD3<Double>, radius: Double) {
        // A move at or above the untouched surface cannot cut.
        if min(p0.z, p1.z) >= top { return }

        let loX = min(p0.x, p1.x) - radius, hiX = max(p0.x, p1.x) + radius
        let loY = min(p0.y, p1.y) - radius, hiY = max(p0.y, p1.y) + radius

        var ix0 = Int(((loX - xmin) / resolution).rounded(.down))
        var ix1 = Int(((hiX - xmin) / resolution).rounded(.up)) + 1
        var iy0 = Int(((loY - ymin) / resolution).rounded(.down))
        var iy1 = Int(((hiY - ymin) / resolution).rounded(.up)) + 1
        ix0 = max(ix0, 0); ix1 = min(ix1, nx)
        iy0 = max(iy0, 0); iy1 = min(iy1, ny)
        if ix0 >= ix1 || iy0 >= iy1 { return }

        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let lenSq = dx * dx + dy * dy
        let r2 = radius * radius

        h.withUnsafeMutableBufferPointer { buf in
            if lenSq < 1e-12 {
                // Pure plunge or dwell: a disc at one XY position.
                let zf = Float(min(p0.z, p1.z))
                for iy in iy0..<iy1 {
                    let gy = ymin + Double(iy) * resolution
                    let ddy = gy - p0.y
                    let row = iy * nx
                    for ix in ix0..<ix1 {
                        let gx = xmin + Double(ix) * resolution
                        let ddx = gx - p0.x
                        if ddx * ddx + ddy * ddy <= r2, buf[row + ix] > zf {
                            buf[row + ix] = zf
                        }
                    }
                }
                return
            }

            for iy in iy0..<iy1 {
                let gy = ymin + Double(iy) * resolution
                let row = iy * nx
                for ix in ix0..<ix1 {
                    let gx = xmin + Double(ix) * resolution
                    // How far along the segment the closest point sits: t
                    // gives the cutter's Z there, so ramps cut at the right
                    // depth rather than an averaged one.
                    var t = ((gx - p0.x) * dx + (gy - p0.y) * dy) / lenSq
                    t = min(max(t, 0), 1)
                    let cx = p0.x + t * dx, cy = p0.y + t * dy
                    let ddx = gx - cx, ddy = gy - cy
                    if ddx * ddx + ddy * ddy <= r2 {
                        let zf = Float(p0.z + (p1.z - p0.z) * t)
                        if buf[row + ix] > zf { buf[row + ix] = zf }
                    }
                }
            }
        }
    }
}

public enum Simulator {
    /// Push moves through the stock in emission order.
    /// Returns the number of segments swept.
    @discardableResult
    public static func run(program: Program, into field: HeightField,
                           radius: Double, maxSag: Double = 0.01,
                           maxDZ: Double = 0.2,
                           from firstMove: Int = 0, through lastMove: Int? = nil) -> Int {
        let end = min(lastMove ?? (program.moves.count - 1), program.moves.count - 1)
        guard firstMove <= end else { return 0 }
        var segs = 0

        for i in firstMove...end {
            let m = program.moves[i]
            let pts = m.isArc ? m.polyline(maxSag: maxSag) : [m.start, m.end]
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                // Split steep moves so a ramp's depth is followed, not averaged.
                let steps = max(1, Int((abs(b.z - a.z) / maxDZ).rounded(.up)))
                if steps == 1 {
                    field.cutSegment(a, b, radius: radius)
                    segs += 1
                } else {
                    for s in 0..<steps {
                        let ta = Double(s) / Double(steps)
                        let tb = Double(s + 1) / Double(steps)
                        field.cutSegment(a + (b - a) * ta, a + (b - a) * tb, radius: radius)
                        segs += 1
                    }
                }
            }
        }
        return segs
    }
}

public extension HeightField {
    /// Restore a previously captured grid. Used to rewind for scrubbing.
    func replace(heights: [Float]) {
        precondition(heights.count == h.count, "grid size mismatch")
        h = heights
    }
}
