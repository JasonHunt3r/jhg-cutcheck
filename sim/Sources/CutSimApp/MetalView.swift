import SwiftUI
import MetalKit
import CutSimCore

/// MTKView that orbits on drag and dollies on scroll.
final class OrbitMTKView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    var onStep: ((Int) -> Void)?
    var onSection: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Shift steps by 10, Option by 100.
        let mag = event.modifierFlags.contains(.option) ? 100
                : event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: onStep?(-mag)      // left
        case 124: onStep?(mag)       // right
        case 125: onSection?(-1)     // down
        case 126: onSection?(1)      // up
        default: super.keyDown(with: event)
        }
    }

    var onPan: ((CGFloat, CGFloat) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        // Option or Shift slides the view; a plain drag spins it.
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            onPan?(event.deltaX, event.deltaY)
        } else {
            onDrag?(event.deltaX, event.deltaY)
        }
    }

    /// Cursor feedback so it is obvious which mode a drag will be.
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
        super.flagsChanged(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }
    override func rightMouseDragged(with event: NSEvent) {
        onPan?(event.deltaX, event.deltaY)
    }
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
    override func magnify(with event: NSEvent) {
        onScroll?(event.magnification * 200)
    }
}

struct CutView: NSViewRepresentable {
    let document: CutDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: Renderer?
        var configuredFor: ObjectIdentifier?
        var patchFor: ObjectIdentifier?
        var lastGeneration: UInt64 = .max
        var lastResetRequest = 0
    }

    func makeNSView(context: Context) -> OrbitMTKView {
        let view = OrbitMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        guard let r = Renderer(view: view) else { return view }
        context.coordinator.renderer = r
        view.delegate = r
        view.sampleCount = 4          // MSAA: stops triangle edges shimmering
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60

        view.onDrag = { dx, dy in
            r.azimuth -= Float(dx) * 0.01
            r.elevation = max(-1.5, min(1.5, r.elevation + Float(dy) * 0.01))
        }
        view.onScroll = { dy in
            r.distance = max(0.5, min(5000, r.distance * Float(1 - dy * 0.01)))
        }
        // Pan across the part, so the detail patch can be aimed at a feature.
        view.onPan = { dx, dy in
            let scale = r.distance * 0.0012
            let right = SIMD3<Float>(-sin(r.azimuth), cos(r.azimuth), 0)
            let up = SIMD3<Float>(-cos(r.azimuth) * sin(r.elevation),
                                  -sin(r.azimuth) * sin(r.elevation),
                                  cos(r.elevation))
            r.target -= right * Float(dx) * scale
            r.target += up * Float(dy) * scale
        }
        let doc = document
        view.onStep = { d in
            MainActor.assumeIsolated { doc.step(d) }
        }
        view.onSection = { d in
            MainActor.assumeIsolated { doc.stepSection(d) }
        }
        r.onCameraSettled = { cx, cy, half in
            MainActor.assumeIsolated { doc.refineDetail(centerX: cx, centerY: cy, halfSize: half) }
        }
        return view
    }

    func updateNSView(_ view: OrbitMTKView, context: Context) {
        guard let r = context.coordinator.renderer, let field = document.field else { return }
        let c = context.coordinator

        let id = ObjectIdentifier(field)
        if c.configuredFor != id {
            r.configure(field: field, resetCamera: c.configuredFor == nil)
            c.configuredFor = id
            c.lastGeneration = document.generation
            c.patchFor = nil
            r.setPatch(nil)
        } else if c.lastGeneration != document.generation {
            r.upload(field: field)
            c.lastGeneration = document.generation
        }

        // The patch is a separate layer drawn over the base, so the base
        // keeps covering everything the patch does not.
        let patchID = document.detailField.map(ObjectIdentifier.init)
        if c.patchFor != patchID {
            r.setPatch(document.detailField)
            c.patchFor = patchID
        }

        if c.lastResetRequest != document.resetViewRequest {
            c.lastResetRequest = document.resetViewRequest
            r.resetTopView(field: field)
        }

        r.wireframe = document.wireframe
    }
}
