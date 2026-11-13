import Foundation
@preconcurrency import Metal
import OSLog

private struct HeatmapGPUPoint {
    var coordinate: SIMD4<Float>
    var value: SIMD4<Float>
}

final class HeatmapScene: @unchecked Sendable {
    let index: HeatmapPointIndex
    let points: any MTLBuffer
    init?(photos: [PhotoRecord], device: any MTLDevice) {
        guard let index = try? HeatmapPointIndex(photos: photos) else { return nil }
        self.index = index
        let packed = index.samples.map { sample in
            let highX = Float(sample.point.x), highY = Float(sample.point.y)
            return HeatmapGPUPoint(coordinate: SIMD4(highX, highY, Float(sample.point.x - Double(highX)), Float(sample.point.y - Double(highY))),
                                   value: SIMD4(Float(sample.count), 0, 0, 0))
        }
        guard !Task.isCancelled else { return nil }
        let bytes = max(MemoryLayout<HeatmapGPUPoint>.stride, packed.count * MemoryLayout<HeatmapGPUPoint>.stride)
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
        if !packed.isEmpty { packed.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        points = buffer
    }
}

struct HeatmapUniforms {
    var fieldSize: SIMD2<UInt32>
    var viewSize: SIMD2<Float>
    var projection: SIMD4<Float>
    var raster: SIMD4<Float>
}

final class HeatmapFieldBuffers {
    let size: CGSize
    let scale: Double
    let halo: Int
    let radius: Int
    let width: Int
    let height: Int
    let impulses: any MTLBuffer
    let weights: any MTLBuffer
    let horizontal: any MTLTexture
    let density: any MTLTexture
    var chargedBytes: Int { width * height * 12 + weights.length }

    init?(size: CGSize, device: any MTLDevice) {
        guard size.width > 0, size.height > 0 else { return nil }
        self.size = size
        // The smooth field needs at most one sample per screen point; final composition uses Retina resolution.
        // Cap working buffers at ~24 MiB even on large displays.
        let expandedWidth = size.width + DensityRaster.radius * 6, expandedHeight = size.height + DensityRaster.radius * 6
        scale = min(1, sqrt(2_000_000 / (expandedWidth * expandedHeight)), 4096 / max(expandedWidth, expandedHeight))
        halo = Int(ceil(DensityRaster.radius * 3 * scale)) + 2
        width = Int(ceil(size.width * scale)) + 2 * halo
        height = Int(ceil(size.height * scale)) + 2 * halo
        let sigma = DensityRaster.radius * scale / 3
        radius = Int(ceil(sigma * 6.5))
        let kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
        guard let horizontal = device.makeTexture(descriptor: descriptor), let density = device.makeTexture(descriptor: descriptor),
              let impulses = device.makeBuffer(length: width * height * 4, options: .storageModePrivate),
              let weights = device.makeBuffer(bytes: kernel, length: kernel.count * 4, options: .storageModeShared) else { return nil }
        self.horizontal = horizontal; self.density = density; self.impulses = impulses; self.weights = weights
    }

    func uniforms(projection: HeatmapProjection, photoCount: Int) -> HeatmapUniforms {
        let highY = Float(projection.camera.y), lowY = Float(projection.camera.y - Double(highY))
        let fixedScale = max(1, min(1024, floor(Double(UInt32.max) / Double(max(1, photoCount)) / 2)))
        return HeatmapUniforms(fieldSize: SIMD2(UInt32(width), UInt32(height)), viewSize: SIMD2(Float(size.width), Float(size.height)),
            projection: SIMD4(highY, lowY, Float(size.width / projection.camera.width * scale), Float(size.height / projection.camera.height * scale)),
            raster: SIMD4(Float(halo), Float(scale), Float(fixedScale), Float(radius)))
    }
}

/// Pipelines are compiled once off the main thread. Frames contain only spatial range selection and GPU work.
final class HeatmapGPU: @unchecked Sendable {
    static let shared: Task<HeatmapGPU?, Never> = Task.detached(priority: .userInitiated) {
        do { return try HeatmapGPU() }
        catch {
            Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "Heatmap").error("Metal setup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let scatter: any MTLComputePipelineState
    private let horizontal: any MTLComputePipelineState
    private let vertical: any MTLComputePipelineState
    private let colorize: any MTLRenderPipelineState

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
        self.device = device; self.queue = queue
        let options = MTLCompileOptions()
        // Preserve compensated coordinates: reassociation would round away the low part at street zoom.
        if #available(macOS 15.0, *) { options.mathMode = .safe }
        else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: HeatmapShader.source, options: options)
        func function(_ name: String) throws -> any MTLFunction {
            guard let result = library.makeFunction(name: name) else { throw RenderError.unavailable }; return result
        }
        scatter = try device.makeComputePipelineState(function: function("scatter"))
        horizontal = try device.makeComputePipelineState(function: function("horizontal"))
        vertical = try device.makeComputePipelineState(function: function("vertical"))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try function("fullscreen"); descriptor.fragmentFunction = try function("colorize")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        colorize = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum RenderError: Error { case unavailable }

    func encode(scene: HeatmapScene, projection: HeatmapProjection, fields: HeatmapFieldBuffers,
                target: any MTLTexture, command: any MTLCommandBuffer) -> Bool {
        guard projection.camera.width > 0, projection.camera.height > 0 else { return false }
        var uniforms = fields.uniforms(projection: projection, photoCount: scene.index.photoCount)
        guard let clear = command.makeBlitCommandEncoder() else { return false }
        clear.fill(buffer: fields.impulses, range: 0..<fields.impulses.length, value: 0); clear.endEncoding()
        let spans = projection.spans(index: scene.index, halo: Double(fields.halo) / fields.scale)
        if !spans.isEmpty {
            guard let buffer = device.makeBuffer(bytes: spans, length: spans.count * MemoryLayout<HeatmapDispatchSpan>.stride, options: .storageModeShared),
                  let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(scatter)
            encoder.setBuffer(scene.points, offset: 0, index: 0); encoder.setBuffer(buffer, offset: 0, index: 1)
            encoder.setBuffer(fields.impulses, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<HeatmapUniforms>.stride, index: 3)
            encoder.dispatchThreadgroups(MTLSize(width: spans.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        }
        let grid = MTLSize(width: fields.width, height: fields.height, depth: 1), group = MTLSize(width: 16, height: 16, depth: 1)
        guard let horizontalPass = command.makeComputeCommandEncoder() else { return false }
        horizontalPass.setComputePipelineState(horizontal)
        horizontalPass.setBuffer(fields.impulses, offset: 0, index: 0)
        horizontalPass.setBytes(&uniforms, length: MemoryLayout<HeatmapUniforms>.stride, index: 1)
        horizontalPass.setBuffer(fields.weights, offset: 0, index: 2); horizontalPass.setTexture(fields.horizontal, index: 0)
        horizontalPass.dispatchThreads(grid, threadsPerThreadgroup: group); horizontalPass.endEncoding()
        guard let verticalPass = command.makeComputeCommandEncoder() else { return false }
        verticalPass.setComputePipelineState(vertical)
        verticalPass.setTexture(fields.horizontal, index: 0); verticalPass.setTexture(fields.density, index: 1)
        verticalPass.setBytes(&uniforms, length: MemoryLayout<HeatmapUniforms>.stride, index: 0)
        verticalPass.setBuffer(fields.weights, offset: 0, index: 1)
        verticalPass.dispatchThreads(grid, threadsPerThreadgroup: group); verticalPass.endEncoding()
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear; descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let render = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        render.setRenderPipelineState(colorize); render.setFragmentTexture(fields.density, index: 0)
        render.setFragmentBytes(&uniforms, length: MemoryLayout<HeatmapUniforms>.stride, index: 0)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); render.endEncoding()
        return true
    }
}
