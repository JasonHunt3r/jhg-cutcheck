import SwiftUI
import MetalKit
import CutSimCore

/// MTKView that orbits on drag and dollies on scroll.
final class OrbitMTKView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    var onPan: ((CGFloat, CGFloat) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            onPan?(event.deltaX, event.deltaY)
        } else {
            onDrag?(event.deltaX, event.deltaY)
        }
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
        r.onCameraSettled = { cx, cy, half in
            MainActor.assumeIsolated { doc.refineDetail(centerX: cx, centerY: cy, halfSize: half) }
        }
        return view
    }

    func updateNSView(_ view: OrbitMTKView, context: Context) {
        guard let r = context.coordinator.renderer,
              let field = document.displayField else { return }
        let id = ObjectIdentifier(field)
        if context.coordinator.configuredFor != id {
            // Only the whole block frames the camera; a detail patch must
            // appear exactly where you were already looking.
            r.configure(field: field, resetCamera: context.coordinator.configuredFor == nil)
            context.coordinator.configuredFor = id
            context.coordinator.lastGeneration = document.generation
        } else if context.coordinator.lastGeneration != document.generation {
            r.upload(field: field)
            context.coordinator.lastGeneration = document.generation
        }
        r.wireframe = document.wireframe
    }
}
