import Metal
import MetalKit
import simd
import CutSimCore

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

    private var heightTexture: MTLTexture?
    private var vertexCount = 0

    // Camera
    var azimuth: Float = -0.6
    var elevation: Float = 0.9
    var distance: Float = 600
    var target = SIMD3<Float>(0, 0, 0)
    var wireframe = false

    private var grid = (nx: 0, ny: 0)
    private var bounds = (xmin: Float(0), ymin: Float(0), res: Float(1),
                          top: Float(0), bottom: Float(-1))

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
              let bp = pipeline("baseVertex", "surfaceFragment") else { return nil }
        surfacePipeline = sp
        basePipeline = bp

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = dev.makeDepthStencilState(descriptor: dd)
    }

    /// Called when a different file is loaded: rebuild the texture and indices.
    func configure(field: HeightField) {
        grid = (field.nx, field.ny)
        bounds = (Float(field.xmin), Float(field.ymin), Float(field.resolution),
                  Float(field.top), Float(field.bottom))

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: field.nx, height: field.ny, mipmapped: false)
        td.usage = [.shaderRead]
        heightTexture = device.makeTexture(descriptor: td)

        vertexCount = max(0, (field.nx - 1) * (field.ny - 1) * 6)

        // Frame the part.
        let w = Float(field.xmax - field.xmin), d = Float(field.ymax - field.ymin)
        target = SIMD3(Float(field.xmin) + w / 2, Float(field.ymin) + d / 2,
                       Float(field.bottom) / 2)
        distance = max(w, d) * 1.5
        upload(field: field)
    }

    func upload(field: HeightField) {
        guard let tex = heightTexture, field.nx == grid.nx, field.ny == grid.ny else { return }
        field.h.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, field.nx, field.ny),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: field.nx * MemoryLayout<Float>.size)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let tex = heightTexture, vertexCount > 0,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let size = view.drawableSize
        let aspect = Float(max(size.width, 1) / max(size.height, 1))

        let eye = target + SIMD3(distance * cos(elevation) * cos(azimuth),
                                 distance * cos(elevation) * sin(azimuth),
                                 distance * sin(elevation))
        let mvp = perspective(fov: .pi / 4, aspect: aspect, near: 1, far: distance * 4)
            * lookAt(eye: eye, center: target, up: SIMD3(0, 0, 1))

        var u = Uniforms(mvp: mvp, xmin: bounds.xmin, ymin: bounds.ymin, res: bounds.res,
                         nx: UInt32(grid.nx), ny: UInt32(grid.ny),
                         top: bounds.top, bottom: bounds.bottom,
                         shade: wireframe ? 0 : 1)

        enc.setDepthStencilState(depthState)
        enc.setTriangleFillMode(wireframe ? .lines : .fill)
        enc.setCullMode(.none)

        enc.setRenderPipelineState(basePipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        enc.setRenderPipelineState(surfacePipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
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
