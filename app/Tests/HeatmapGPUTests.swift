import XCTest
@preconcurrency import Metal

final class HeatmapGPUTests: XCTestCase {
    private static let engine = Result { try HeatmapGPU() }
    private func gpu() throws -> HeatmapGPU {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this test host") }
        return try Self.engine.get()
    }
    private func photo(_ id: String, latitude: Double = 0, longitude: Double = 0) -> PhotoRecord {
        PhotoRecord(id: id, latitude: latitude, longitude: longitude, date: nil, modified: nil, width: 100, height: 100, favorite: false)
    }

    func testPackedIndexCombinesCoincidentCoordinatesAndDateLineEndpoints() throws {
        let records = (0..<100_000).map { photo("\($0)") } + [photo("east", longitude: 180), photo("west", longitude: -180)]
        let index = try HeatmapPointIndex(photos: records)
        XCTAssertEqual(index.samples.count, 2)
        XCTAssertEqual(index.photoCount, 100_002)
        XCTAssertEqual(index.samples.map(\.count).sorted(), [2, 100_000])
    }

    func testSpatialRangesCoverVisiblePointsWithoutDuplicateDispatches() throws {
        let index = try HeatmapPointIndex(photos: PerformanceReport.syntheticPhotos(count: 100_000))
        for x in [0.0, 0.25, 0.49, 0.98] {
            let rect = AtlasRect(x: x, y: 0.3, width: 0.08, height: 0.1)
            let ranges = index.ranges(in: rect)
            let indices = ranges.flatMap(Array.init)
            XCTAssertEqual(indices.count, Set(indices).count)
            let candidates = Set(indices)
            for (i, sample) in index.samples.enumerated() where rect.contains(sample.point) { XCTAssertTrue(candidates.contains(i)) }
            XCTAssertLessThan(indices.count, index.samples.count / 2)
        }
    }

    func testCancelledIndexBuildRejectsItsResult() async {
        let records = [photo("one")]
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HeatmapPointIndex(photos: records)
        }
        do { _ = try await worker.value; XCTFail("Cancelled work must not return a scene") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testContinuousZoomDoesNotBlankSingleLocationOrJumpItsIntensity() throws {
        let engine = try gpu(), size = CGSize(width: 256, height: 256)
        let scene = try XCTUnwrap(HeatmapScene(photos: [photo("one")], device: engine.device))
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 512, height: 512)
        var peaks: [UInt8] = []
        for step in 0...32 {
            let span = 0.02 / pow(2, Double(step) / 16)
            let camera = AtlasRect(x: 0.5 - span / 2, y: 0.5 - span / 2, width: span, height: span)
            let bytes = try render(engine, scene: scene, fields: fields, target: target, camera: camera)
            let alpha = bytes[(256 * 512 + 256) * 4 + 3]
            XCTAssertGreaterThan(alpha, 100, "A warm scene must render at every fractional zoom, including integer boundaries")
            peaks.append(alpha)
        }
        XCTAssertLessThanOrEqual(Int(peaks.max()!) - Int(peaks.min()!), 2)
    }

    func testNearbyLocationsMorphBeforeColorization() throws {
        let engine = try gpu(), size = CGSize(width: 256, height: 256)
        let scene = try XCTUnwrap(HeatmapScene(photos: [photo("left", longitude: -0.0072), photo("right", longitude: 0.0072)], device: engine.device))
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 256, height: 256)
        var alpha: [Int] = []
        for step in 0...32 {
            let span = 0.001 / pow(2, Double(step) / 32)
            let bytes = try render(engine, scene: scene, fields: fields, target: target,
                camera: AtlasRect(x: 0.5 - span / 2, y: 0.5 - span / 2, width: span, height: span))
            alpha.append(Int(bytes[(128 * 256 + 128) * 4 + 3]))
        }
        XCTAssertGreaterThan(alpha.first!, alpha.last! + 20, "The bridge between the peaks must physically separate on zoom")
        XCTAssertLessThan(zip(alpha, alpha.dropFirst()).map { abs($0 - $1) }.max()!, 10, "Contours must change continuously, not at scale thresholds")
    }

    func testPanAndDateLineUseOneContinuousField() throws {
        let engine = try gpu(), size = CGSize(width: 256, height: 256)
        let scene = try XCTUnwrap(HeatmapScene(photos: [photo("east", longitude: 179.8), photo("west", longitude: -179.8)], device: engine.device))
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 256, height: 256)
        let before = try render(engine, scene: scene, fields: fields, target: target, camera: AtlasRect(x: 0.99, y: 0.49, width: 0.02, height: 0.02))
        let after = try render(engine, scene: scene, fields: fields, target: target, camera: AtlasRect(x: 0.99125, y: 0.49, width: 0.02, height: 0.02))
        XCTAssertGreaterThan(before[(128 * 256 + 121) * 4 + 3], 0)
        XCTAssertGreaterThan(before[(128 * 256 + 135) * 4 + 3], 0)
        var difference = 0
        for y in 64..<192 { for x in 32..<224 { for channel in 0..<4 {
            difference = max(difference, abs(Int(before[(y * 256 + x) * 4 + channel]) - Int(after[(y * 256 + x - 16) * 4 + channel])))
        } } }
        XCTAssertLessThanOrEqual(difference, 2)
    }

    func testWorkingBuffersStayBoundedOnLargeDisplays() throws {
        let engine = try gpu()
        let buffers = try XCTUnwrap(HeatmapFieldBuffers(size: CGSize(width: 6000, height: 3000), device: engine.device))
        XCTAssertLessThan(buffers.chargedBytes, 26 * 1024 * 1024)
        XCTAssertLessThanOrEqual(buffers.width, 4096)
        XCTAssertLessThanOrEqual(buffers.height, 4096)
    }

    func testDeepZoomPreservesSubpixelCoordinatesAndClearsEmptyFrames() throws {
        let engine = try gpu(), size = CGSize(width: 256, height: 256)
        let record = photo("precise", latitude: 16.061, longitude: 108.22), point = record.point!
        let scene = try XCTUnwrap(HeatmapScene(photos: [record], device: engine.device))
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 256, height: 256)
        let span = 0.00000001
        let pixels = try render(engine, scene: scene, fields: fields, target: target,
            camera: AtlasRect(x: point.x - span / 2, y: point.y - span / 2, width: span, height: span))
        XCTAssertGreaterThan(pixels[(128 * 256 + 128) * 4 + 3], 100)
        let empty = try render(engine, scene: scene, fields: fields, target: target,
            camera: AtlasRect(x: point.x + span, y: point.y + span, width: span, height: span))
        XCTAssertTrue(empty.allSatisfy { $0 == 0 }, "A frame must not retain stale density after leaving a location")
    }

    func testHundredThousandDistinctLocationsOnGPU() throws {
        let engine = try gpu()
        let records = (0..<100_000).map { i in
            photo("unique-\(i)", latitude: Double((i * 32_452_843) % 1_000_033) / 1_000_033 * 160 - 80,
                  longitude: Double((i * 15_485_863) % 1_000_003) / 1_000_003 * 360 - 180)
        }
        let scene = try XCTUnwrap(HeatmapScene(photos: records, device: engine.device))
        XCTAssertEqual(scene.index.samples.count, 100_000)
        let size = CGSize(width: 1000, height: 700)
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 2000, height: 1400)
        var timings: [Double] = []
        for step in 0..<20 {
            let span = 1 / pow(2, Double(step) / 12)
            let command = try XCTUnwrap(engine.queue.makeCommandBuffer())
            XCTAssertTrue(engine.encode(scene: scene,
                projection: HeatmapProjection(camera: AtlasRect(x: 0.5 - span / 2, y: 0.5 - span * 0.35, width: span, height: span * 0.7), size: size),
                fields: fields, target: target, command: command))
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            if step > 2 { timings.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
        }
        let p95 = timings.sorted()[Int(Double(timings.count - 1) * 0.95)]
        print("HEATMAP_DISTINCT_GPU_BENCHMARK uniquePoints=100000 gpuP95=\(p95)ms pointBufferBytes=\(scene.points.length)")
        XCTAssertLessThan(p95, 100)
    }

    func testHundredThousandPhotoGPUFramesAndLegacyRasterCost() throws {
        let engine = try gpu(), records = PerformanceReport.syntheticPhotos(count: 100_000)
        let size = CGSize(width: 1000, height: 700)
        let scene = try XCTUnwrap(HeatmapScene(photos: records, device: engine.device))
        let fields = try XCTUnwrap(HeatmapFieldBuffers(size: size, device: engine.device))
        let target = try texture(engine, width: 2000, height: 1400)
        var cpu: [Double] = [], gpu: [Double] = []
        for step in 0..<30 {
            let span = 1 / pow(2, Double(step) / 12)
            let projection = HeatmapProjection(camera: AtlasRect(x: 0.5 - span / 2, y: 0.5 - span * 0.35, width: span, height: span * 0.7), size: size)
            let command = try XCTUnwrap(engine.queue.makeCommandBuffer())
            let start = ContinuousClock.now
            XCTAssertTrue(engine.encode(scene: scene, projection: projection, fields: fields, target: target, command: command))
            cpu.append(milliseconds(start.duration(to: .now)))
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            if step >= 3 { gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
        }
        let spatial = SpatialIndex(photos: records), start = ContinuousClock.now
        XCTAssertNotNil(DensityRaster.image(index: spatial, rect: AtlasRect(x: 0, y: 0.15, width: 1, height: 0.7), width: 2000, height: 1400, scale: 2))
        let legacy = milliseconds(start.duration(to: .now))
        let p95CPU = cpu.sorted()[Int(Double(cpu.count - 1) * 0.95)], p95GPU = gpu.sorted()[Int(Double(gpu.count - 1) * 0.95)]
        print("HEATMAP_GPU_BENCHMARK samples=100000 uniquePoints=\(scene.index.samples.count) output=2000x1400 field=\(fields.width)x\(fields.height) cpuEncodeP95=\(p95CPU)ms gpuP95=\(p95GPU)ms legacyRetinaRaster=\(legacy)ms workingBytes=\(fields.chargedBytes)")
        XCTAssertLessThan(p95CPU, 100)
        XCTAssertLessThan(p95GPU, 100)
    }

    private func texture(_ engine: HeatmapGPU, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        return try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
    }
    private func render(_ engine: HeatmapGPU, scene: HeatmapScene, fields: HeatmapFieldBuffers, target: any MTLTexture, camera: AtlasRect) throws -> [UInt8] {
        let command = try XCTUnwrap(engine.queue.makeCommandBuffer())
        XCTAssertTrue(engine.encode(scene: scene, projection: HeatmapProjection(camera: camera, size: fields.size), fields: fields, target: target, command: command))
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var pixels = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&pixels, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return pixels
    }
    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
