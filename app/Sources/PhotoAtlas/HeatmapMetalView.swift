import AppKit
@preconcurrency import MapKit
@preconcurrency import MetalKit
import OSLog

/// A transparent, event-driven density surface. It never discards a scale level during a gesture.
@MainActor
final class HeatmapMetalView: MTKView, MTKViewDelegate {
    weak var map: MKMapView?
    var onFailure: (() -> Void)?
    private var gpu: HeatmapGPU?
    private var scene: HeatmapScene?
    private var fields: HeatmapFieldBuffers?
    private var sceneTask: Task<Void, Never>?
    private var generation = RequestGeneration()
    private let inFlight = DispatchSemaphore(value: 2)
    private var stopped = false
    private var frames = 0
    private var totalCPU = 0.0
    private var maxCPU = 0.0
    private let diagnostics = ProcessInfo.processInfo.arguments.contains("--heatmap-diagnostics")
    private var busyFrames = 0
    private var missingDrawables = 0
    private var maxProjectionError = 0.0

    init?(map: MKMapView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.map = map
        super.init(frame: map.bounds, device: device)
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = true
        preferredFramesPerSecond = 60
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        delegate = self; wantsLayer = true; layer?.isOpaque = false
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPhotos(_ photos: [PhotoRecord]) {
        sceneTask?.cancel()
        let version = generation.advance()
        sceneTask = Task { [weak self] in
            let engine = await HeatmapGPU.shared.value
            guard !Task.isCancelled else { return }
            guard let gpu = engine else { self?.onFailure?(); return }
            let worker = Task.detached(priority: .userInitiated) { HeatmapScene(photos: photos, device: gpu.device) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, !stopped, generation.accepts(version) else { return }
            guard let result else { onFailure?(); return }
            self.gpu = gpu; scene = result
            if ProcessInfo.processInfo.arguments.contains("--heatmap-diagnostics") {
                Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "Heatmap").notice("Metal scene active: photos=\(result.index.photoCount) points=\(result.index.samples.count)")
            }
            needsDisplay = true
        }
    }

    func cameraChanged() { if !stopped, !isHidden { needsDisplay = true } }
    func cameraWillMove() {
        if !stopped, !isHidden { enableSetNeedsDisplay = false; isPaused = false }
    }
    func cameraDidStop() {
        isPaused = true; enableSetNeedsDisplay = true; cameraChanged()
        if diagnostics {
            Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "Heatmap").notice("Metal settled: frames=\(self.frames) busy=\(self.busyFrames) missingDrawable=\(self.missingDrawables) projectionError=\(self.maxProjectionError)pt")
        }
    }
    func stop() {
        stopped = true; isPaused = true; sceneTask?.cancel(); _ = generation.advance()
        delegate = nil; scene = nil; fields = nil; releaseDrawables()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { cameraChanged() }
    func draw(in view: MTKView) {
        guard !stopped, !isHidden, let gpu, let scene, let map,
              bounds.width > 0, bounds.height > 0, map.visibleMapRect.width > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            if diagnostics { busyFrames += 1 }
            needsDisplay = true; return
        }
        let start = ContinuousClock.now
        if fields?.size != bounds.size { fields = HeatmapFieldBuffers(size: bounds.size, device: gpu.device) }
        guard let fields, let drawable = currentDrawable, let command = gpu.queue.makeCommandBuffer() else {
            if diagnostics { missingDrawables += 1 }
            inFlight.signal(); return
        }
        let rect = map.canvasMapRect, world = MKMapRect.world.width
        if diagnostics {
            let projectedCenter = map.convert(MKMapPoint(x: rect.midX, y: rect.midY).coordinate, toPointTo: map)
            maxProjectionError = max(maxProjectionError, hypot(projectedCenter.x - map.bounds.midX, projectedCenter.y - map.bounds.midY))
        }
        let projection = HeatmapProjection(camera: AtlasRect(x: rect.minX / world, y: rect.minY / world, width: rect.width / world, height: rect.height / world), size: bounds.size)
        guard gpu.encode(scene: scene, projection: projection, fields: fields, target: drawable.texture, command: command) else { inFlight.signal(); return }
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                Task { @MainActor [weak self] in self?.onFailure?() }
            }
        }
        command.commit()
        // Match MapKit's Core Animation transaction instead of presenting a frame later than the map.
        command.waitUntilScheduled(); drawable.present()
        if diagnostics {
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            frames += 1; totalCPU += ms; maxCPU = max(maxCPU, ms)
            if frames % 30 == 0 {
                Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "Heatmap").notice("GPU field frames=\(self.frames) cpuMean=\(self.totalCPU / Double(self.frames))ms cpuMax=\(self.maxCPU)ms buffers=\(fields.chargedBytes)")
            }
        }
    }
}
