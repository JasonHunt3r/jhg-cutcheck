import SwiftUI
import MetalKit
import CutSimCore

/// MTKView that orbits on drag and dollies on scroll.
final class OrbitMTKView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, event.deltaY)
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
        var lastGeneration: UInt64 = .max
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
            r.distance = max(20, min(5000, r.distance * Float(1 - dy * 0.01)))
        }
        return view
    }

    func updateNSView(_ view: OrbitMTKView, context: Context) {
        guard let r = context.coordinator.renderer, let field = document.field else { return }
        let id = ObjectIdentifier(field)
        if context.coordinator.configuredFor != id {
            r.configure(field: field)
            context.coordinator.configuredFor = id
            context.coordinator.lastGeneration = document.generation
        } else if context.coordinator.lastGeneration != document.generation {
            r.upload(field: field)
            context.coordinator.lastGeneration = document.generation
        }
        r.wireframe = document.wireframe
    }
}
