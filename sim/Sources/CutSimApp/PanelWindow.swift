import AppKit

/// A utility panel that snaps to its neighbours and to the screen.
///
/// Snapping is done by overriding the frame setters rather than reacting to
/// move notifications: AppKit drives a drag through these, so intercepting
/// here corrects the frame before it is ever drawn. Correcting afterwards
/// fights the drag and visibly stutters.
final class PanelWindow: NSPanel {

    /// Frames of the other windows worth snapping to, supplied by the manager.
    var neighbours: () -> [NSRect] = { [] }

    /// How close an edge must be, in points, before it snaps.
    static let snapDistance: CGFloat = 10

    private var adjusting = false

    override var canBecomeKey: Bool { true }

    // A move: only the origin shifts.
    override func setFrameOrigin(_ point: NSPoint) {
        guard !adjusting else { super.setFrameOrigin(point); return }
        adjusting = true
        defer { adjusting = false }
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(snapped(proposed).origin)
    }

    // A resize: edges move independently, so snap the whole rect.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !adjusting, inLiveResize else {
            super.setFrame(frameRect, display: flag)
            return
        }
        adjusting = true
        defer { adjusting = false }
        super.setFrame(snapped(frameRect), display: flag)
    }

    /// Nudge each edge to the nearest neighbouring or screen edge in range.
    private func snapped(_ rect: NSRect) -> NSRect {
        var r = rect
        let t = Self.snapDistance
        var targets = neighbours()
        if let vis = screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            targets.append(vis)
        }
        guard !targets.isEmpty else { return r }

        var bestDX: CGFloat?, bestDY: CGFloat?
        func considerX(_ delta: CGFloat) {
            if abs(delta) <= t, abs(delta) < abs(bestDX ?? .greatestFiniteMagnitude) { bestDX = delta }
        }
        func considerY(_ delta: CGFloat) {
            if abs(delta) <= t, abs(delta) < abs(bestDY ?? .greatestFiniteMagnitude) { bestDY = delta }
        }

        for o in targets {
            // Butt against the neighbour...
            considerX(o.maxX - r.minX)
            considerX(o.minX - r.maxX)
            considerY(o.maxY - r.minY)
            considerY(o.minY - r.maxY)
            // ...or line up with it, which is what makes stacks flush.
            considerX(o.minX - r.minX)
            considerX(o.maxX - r.maxX)
            considerY(o.minY - r.minY)
            considerY(o.maxY - r.maxY)
        }

        r.origin.x += bestDX ?? 0
        r.origin.y += bestDY ?? 0
        return r
    }
}
