import Metal
import MetalKit
import simd
import CutSimCore

/// One point on the toolpath. Layout matches `PathVertex` in the shader.
struct PathVertex {
    var x: Float, y: Float, z: Float
    var category: UInt32      // 0 travel above, 1 travel at depth, 2 cut, 3 arc, 4 plunge
    var moveIndex: UInt32
    var section: UInt32
}

struct PathUniforms {
    var mvp: simd_float4x4
    var maxMove: UInt32
    var mask: UInt32
    var colorMode: UInt32
    var sectionCount: UInt32
    var pointSize: Float
}

/// Which parts of the path to draw.
struct PathOptions: Equatable {
    var travelAbove = false
    var travelAtDepth = true
    var cuts = false
    var plunges = true
    var colorBySection = false
    var followScrub = true

    var isEmpty: Bool { !(travelAbove || travelAtDepth || cuts || plunges) }

    /// Arcs share the `cuts` toggle; they are coloured differently, not
    /// switched separately.
    var mask: UInt32 {
        var m: UInt32 = 0
        if travelAbove   { m |= 1 << 0 }
        if travelAtDepth { m |= 1 << 1 }
        if cuts          { m |= (1 << 2) | (1 << 3) }
        if plunges       { m |= 1 << 4 }
        return m
    }
}

struct Uniforms {
    var mvp: simd_float4x4
    var xmin: Float
    var ymin: Float
    var res: Float
    var nx: UInt32
    var ny: UInt32
    var top: Float
    var bottom: Float
    var shade: Float
}

/// Draws the height grid as displaced geometry straight from a texture.
/// Nothing is meshed on the CPU, so re-showing a different moment in the
/// program costs one texture upload.
final class Renderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var surfacePipeline: MTLRenderPipelineState!
    private var basePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    /// One height grid ready to draw. The base covers the whole block; a
    /// patch covers just what you are looking at, at finer detail.
    private struct Layer {
        var texture: MTLTexture
        var nx: Int, ny: Int
        var xmin: Float, ymin: Float, res: Float
        var vertexCount: Int
    }
    private var base: Layer?
    private var patch: Layer?

    private var pathPipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var lineBuffer: MTLBuffer?
    private var lineCount = 0
    private var plungeBuffer: MTLBuffer?
    private var plungeCount = 0
    private var sectionCount: UInt32 = 1

    var pathOptions = PathOptions()
    var currentMove: Int = 0

    // Camera
    var azimuth: Float = -0.6
    var elevation: Float = 0.9
    var distance: Float = 600
    var target = SIMD3<Float>(0, 0, 0)
    var wireframe = false

    private var depthRange = (top: Float(0), bottom: Float(-1))
    private var lastAspect: Float = 1.6

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q
        super.init()

        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)

        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: shaderSource, options: nil)
        } catch {
            NSLog("cutsim: shader compile failed: \(error)")
            return nil
        }

        func pipeline(_ vertexFn: String, _ fragFn: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vertexFn)
            d.fragmentFunction = lib.makeFunction(name: fragFn)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let sp = pipeline("surfaceVertex", "surfaceFragment"),
              let bp = pipeline("baseVertex", "surfaceFragment"),
              let pp = pipeline("pathVertex", "pathFragment") else { return nil }
        surfacePipeline = sp
        basePipeline = bp
        pathPipeline = pp
        pointPipeline = pp

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = dev.makeDepthStencilState(descriptor: dd)
    }

    /// Fires once the camera has been still for a few frames, with the
    /// centre and half-width of what is on screen, in millimetres.
    var onCameraSettled: ((Double, Double, Double) -> Void)?
    private var settleCounter = 0
    private var lastCam = SIMD3<Float>(0, 0, 0)

    private func makeLayer(_ field: HeightField) -> Layer? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: field.nx, height: field.ny, mipmapped: false)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        var layer = Layer(texture: tex, nx: field.nx, ny: field.ny,
                          xmin: Float(field.xmin), ymin: Float(field.ymin),
                          res: Float(field.resolution),
                          vertexCount: max(0, (field.nx - 1) * (field.ny - 1) * 6))
        write(field, into: &layer)
        return layer
    }

    private func write(_ field: HeightField, into layer: inout Layer) {
        field.h.withUnsafeBytes { raw in
            layer.texture.replace(region: MTLRegionMake2D(0, 0, field.nx, field.ny),
                                  mipmapLevel: 0,
                                  withBytes: raw.baseAddress!,
                                  bytesPerRow: field.nx * MemoryLayout<Float>.size)
        }
    }

    /// The whole block. `resetCamera` frames it.
    func configure(field: HeightField, resetCamera: Bool = true) {
        depthRange = (Float(field.top), Float(field.bottom))
        base = makeLayer(field)
        if resetCamera { frame(field) }
    }

    func upload(field: HeightField) {
        guard var b = base, field.nx == b.nx, field.ny == b.ny else { return }
        write(field, into: &b)
        base = b
    }

    /// Build the toolpath geometry once per file.
    ///
    /// Line segments rather than strips: a strip would need restarts between
    /// moves, and pairs keep the buffer trivial to build and index-free.
    /// Visibility is decided in the shader from `moveIndex`, so scrubbing
    /// never rebuilds this.
    func setPath(program: Program, surfaceTop: Double) {
        var lines: [PathVertex] = []
        var plunges: [PathVertex] = []
        lines.reserveCapacity(program.moves.count * 2)
        sectionCount = UInt32(max(program.sections.count, 1))

        for (i, m) in program.moves.enumerated() {
            let section = UInt32(m.section ?? 0)
            let idx = UInt32(i)

            // A vertical move below the surface is a plunge: mark its point.
            if m.xyLength < 1e-6, m.dz < -1e-6, m.end.z < surfaceTop {
                plunges.append(PathVertex(x: Float(m.end.x), y: Float(m.end.y),
                                          z: Float(m.end.z), category: 4,
                                          moveIndex: idx, section: section))
                continue
            }

            let category: UInt32
            if m.isRapid {
                category = m.minZ < surfaceTop ? 1 : 0    // at depth, or clear
            } else {
                category = m.isArc ? 3 : 2
            }

            // 0.1mm sag is plenty for a line you are looking at, and keeps
            // the buffer small on arc-heavy files.
            let pts = m.isArc ? m.polyline(maxSag: 0.1) : [m.start, m.end]
            for k in 0..<(pts.count - 1) {
                for p in [pts[k], pts[k + 1]] {
                    lines.append(PathVertex(x: Float(p.x), y: Float(p.y), z: Float(p.z),
                                            category: category, moveIndex: idx,
                                            section: section))
                }
            }
        }

        lineCount = lines.count
        lineBuffer = lines.isEmpty ? nil : device.makeBuffer(
            bytes: lines, length: lines.count * MemoryLayout<PathVertex>.stride,
            options: .storageModeShared)

        plungeCount = plunges.count
        plungeBuffer = plunges.isEmpty ? nil : device.makeBuffer(
            bytes: plunges, length: plunges.count * MemoryLayout<PathVertex>.stride,
            options: .storageModeShared)
    }

    /// The fine patch drawn over the base. Passing nil clears it.
    func setPatch(_ field: HeightField?) {
        guard let field else { patch = nil; return }
        patch = makeLayer(field)
    }

    func frame(_ field: HeightField) {
        let w = Float(field.xmax - field.xmin), d = Float(field.ymax - field.ymin)
        target = SIMD3(Float(field.xmin) + w / 2, Float(field.ymin) + d / 2,
                       Float(field.bottom) / 2)
        distance = max(w, d) * 1.5
    }

    /// Straight down, part filling the view.
    func resetTopView(field: HeightField?) {
        azimuth = -.pi / 2
        elevation = .pi / 2 - 0.004
        if let field { frame(field) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let base,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let size = view.drawableSize
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        lastAspect = aspect

        // Ask for a finer patch once the camera holds still.
        let cam = SIMD3(azimuth, elevation, distance) + target
        if simd_length(cam - lastCam) > 0.01 {
            lastCam = cam
            settleCounter = 0
        } else if settleCounter >= 0 {
            settleCounter += 1
            if settleCounter == 12 {   // ~0.2s at 60fps
                settleCounter = -1
                let half = visibleHalfSpan()
                let tx = Double(target.x), ty = Double(target.y)
                DispatchQueue.main.async { [weak self] in
                    self?.onCameraSettled?(tx, ty, half)
                }
            }
        }

        let eye = target + SIMD3(distance * cos(elevation) * cos(azimuth),
                                 distance * cos(elevation) * sin(azimuth),
                                 distance * sin(elevation))
        // Straight down would make the usual up vector parallel to the view.
        let up: SIMD3<Float> = abs(elevation) > 1.45
            ? SIMD3(-cos(azimuth), -sin(azimuth), 0)
            : SIMD3(0, 0, 1)
        let mvp = perspective(fov: .pi / 4, aspect: aspect, near: 0.2, far: distance * 6)
            * lookAt(eye: eye, center: target, up: up)

        func uniforms(for l: Layer) -> Uniforms {
            Uniforms(mvp: mvp, xmin: l.xmin, ymin: l.ymin, res: l.res,
                     nx: UInt32(l.nx), ny: UInt32(l.ny),
                     top: depthRange.top, bottom: depthRange.bottom,
                     shade: wireframe ? 0 : 1)
        }

        enc.setDepthStencilState(depthState)
        enc.setTriangleFillMode(wireframe ? .lines : .fill)
        enc.setCullMode(.none)

        var baseU = uniforms(for: base)
        enc.setRenderPipelineState(basePipeline)
        enc.setVertexBytes(&baseU, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        enc.setRenderPipelineState(surfacePipeline)
        enc.setVertexBytes(&baseU, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexTexture(base.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: base.vertexCount)

        // The patch covers only part of the view; the base stays underneath so
        // anything outside it degrades to coarse rather than disappearing.
        if let patch, patch.vertexCount > 0 {
            var patchU = uniforms(for: patch)
            enc.setDepthBias(-2.0, slopeScale: -1.0, clamp: -0.01)
            enc.setVertexBytes(&patchU, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexTexture(patch.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: patch.vertexCount)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        // Toolpath over the material. Depth-tested so it is occluded by the
        // part, but biased forward so a line lying on the surface it cut is
        // not lost to z-fighting.
        if !pathOptions.isEmpty {
            var pu = PathUniforms(
                mvp: mvp,
                maxMove: UInt32(pathOptions.followScrub ? currentMove : Int.max >> 1),
                mask: pathOptions.mask,
                colorMode: pathOptions.colorBySection ? 1 : 0,
                sectionCount: sectionCount,
                pointSize: 7)
            enc.setDepthBias(-8.0, slopeScale: -2.0, clamp: -0.05)
            enc.setTriangleFillMode(.fill)

            if let lb = lineBuffer, lineCount > 0 {
                enc.setRenderPipelineState(pathPipeline)
                enc.setVertexBuffer(lb, offset: 0, index: 0)
                enc.setVertexBytes(&pu, length: MemoryLayout<PathUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
            }
            if let pb = plungeBuffer, plungeCount > 0, pathOptions.plunges {
                enc.setRenderPipelineState(pointPipeline)
                enc.setVertexBuffer(pb, offset: 0, index: 0)
                enc.setVertexBytes(&pu, length: MemoryLayout<PathUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: plungeCount)
            }
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// Half-width of what the camera can see on the part, in mm.
    ///
    /// Vertical field of view alone is not enough: the window is wider than
    /// it is tall, and a tilted camera sees a much longer stretch of the
    /// part than a perpendicular one. Undersizing this is what truncated
    /// the patch.
    private func visibleHalfSpan() -> Double {
        let halfV = distance * tan(Float.pi / 8)
        let halfH = halfV * lastAspect
        var half = max(halfH, halfV)
        let tilt = max(sin(abs(elevation)), 0.25)   // grazing views see further
        half /= tilt
        return Double(half) * 1.3                   // margin for orbiting
    }

}

// MARK: - matrices

func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fov * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (SIMD4(x, 0, 0, 0),
                                   SIMD4(0, y, 0, 0),
                                   SIMD4(0, 0, z, -1),
                                   SIMD4(0, 0, z * near, 0)))
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0),
                                   SIMD4(s.y, u.y, -f.y, 0),
                                   SIMD4(s.z, u.z, -f.z, 0),
                                   SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
}
