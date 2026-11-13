import AppKit
import MapKit
import Observation
import Photos

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case preparing, scanning, ready, denied, failed(String) }
    var phase: Phase = .preparing
    var photos: [PhotoRecord] = []
    var albums: [AlbumRecord] = []
    var index = SpatialIndex(photos: [])
    var revision = 0
    var filters = PhotoFilters() { didSet { applyFilters() } }
    var filteredCount = 0
    var mappedCount = 0
    var gallery: [PhotoRecord] = []
    var gallerySections: [GallerySection] = []
    var galleryRevision = 0
    var selectedID: String?
    var viewerID: String?
    var selection: AtlasRect?
    var selectionCenter: AtlasPoint?
    var selectionRadius: Double = 0
    var selectionToken = 0
    var viewport: AtlasRect?
    var showHeatmap = true
    var satellite = UserDefaults.standard.bool(forKey: "satellite") { didSet { if !PreviewLibrary.enabled { UserDefaults.standard.set(satellite, forKey: "satellite") } } }
    var showGallery = true
    var mapPanelInset: CGFloat = 364
    var mapViewportLayout = MapViewportLayout()
    var zoomToken = 0
    var zoomFactor = 1.0
    func zoom(_ factor: Double) { zoomFactor = factor; zoomToken += 1 }
    var cameraRequest: MKMapRect?
    var cameraToken = 0
    var cameraFitsContent = false
    var exportRequest = 0
    var saveExport = false
    var isExporting = false
    var notice: String?
    var exportError: String?
    var queryMilliseconds = 0.0
    var refreshing = false
    var selectedPhoto: PhotoRecord? { photos.first { $0.id == selectedID } }
    var viewerPhoto: PhotoRecord? { gallery.first { $0.id == viewerID } }

    @ObservationIgnored private let library = PhotoLibraryService()
    @ObservationIgnored private let libraryLoader: (@MainActor () async throws -> LibrarySnapshot)?
    let isProject: Bool

    init(isProject: Bool = false, libraryLoader: (@MainActor () async throws -> LibrarySnapshot)? = nil) {
        self.isProject = isProject
        self.libraryLoader = libraryLoader
    }

    func refreshLibrary() { scheduleRefresh() }
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var filterGeneration = RequestGeneration()
    @ObservationIgnored private var queryGeneration = RequestGeneration()
    @ObservationIgnored private var loadGeneration = RequestGeneration()
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var restoredCamera = false
    @ObservationIgnored private var refreshPending = false

    func load() async {
        guard !refreshing else { return }
        let generation = loadGeneration.advance()
        refreshing = true
        if !hasLoaded { phase = .scanning }
        library.onChange = { [weak self] in self?.scheduleRefresh() }
        do {
            if PreviewLibrary.denied { throw PhotoLibraryError.accessDenied }
            let snapshot: LibrarySnapshot
            if PreviewLibrary.enabled && ProcessInfo.processInfo.arguments.contains("--slow-library") {
                try await Task.sleep(for: .seconds(20))
            }
            if let libraryLoader { snapshot = try await libraryLoader() }
            else { snapshot = PreviewLibrary.enabled ? PreviewLibrary.snapshot() : try await library.start(requireFullAccess: isProject) }
            guard !Task.isCancelled, loadGeneration.accepts(generation) else { return }
            if hasLoaded && photos == snapshot.photos && albums == snapshot.albums {
                phase = .ready
                if !restoredCamera { applyFilters() }
                refreshing = false
                if refreshPending { refreshPending = false; scheduleRefresh() }
                return
            }
            photos = snapshot.photos; albums = snapshot.albums
            PhotoImageLoader.shared.invalidate()
            if let id = selectedID, !photos.contains(where: { $0.id == id }) { selectedID = nil }
            if let id = viewerID, !photos.contains(where: { $0.id == id }) { viewerID = nil }
            if let id = filters.albumID, !albums.contains(where: { $0.id == id }) { filters.albumID = nil }
            if !hasLoaded && ProcessInfo.processInfo.arguments.contains("--benchmark") {
                let records = photos
                Task { await PerformanceReport.saveDiagnostics(photos: records) }
            }
            hasLoaded = true
            applyFilters()
            phase = .ready
        } catch PhotoLibraryError.accessDenied {
            guard loadGeneration.accepts(generation), !Task.isCancelled else { return }
            filterTask?.cancel(); queryTask?.cancel()
            _ = filterGeneration.advance(); _ = queryGeneration.advance()
            photos = []; gallery = []; gallerySections = []; albums = []; index = SpatialIndex(photos: []); revision += 1
            filteredCount = 0; mappedCount = 0; galleryRevision += 1
            selectedID = nil; viewerID = nil; hasLoaded = false
            PhotoImageLoader.shared.invalidate()
            phase = .denied
        } catch {
            guard loadGeneration.accepts(generation), !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
        refreshing = false
        if refreshPending { refreshPending = false; scheduleRefresh() }
    }

    func stop() {
        _ = loadGeneration.advance()
        library.stop(); filterTask?.cancel(); queryTask?.cancel(); refreshTask?.cancel()
        refreshing = false; refreshPending = false
    }

    func checkPermission() {
        guard !PreviewLibrary.enabled, libraryLoader == nil else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .denied || status == .restricted || (phase != .ready && !refreshing) { Task { await load() } }
    }

    private func scheduleRefresh() {
        if refreshing { refreshPending = true; return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func applyFilters() {
        filterTask?.cancel()
        let generation = filterGeneration.advance()
        let photos = photos, filters = filters
        let ids = albums.first { $0.id == filters.albumID }?.photoIDs
        filterTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                let filtered = photos.filter { filters.matches($0, albumIDs: ids) }
                return (SpatialIndex(photos: filtered), filtered.count)
            }.value
            guard !Task.isCancelled, filterGeneration.accepts(generation) else { return }
            index = result.0; filteredCount = result.1; mappedCount = result.0.photos.count; revision += 1
            if let id = selectedID, !index.photos.contains(where: { $0.id == id }) { selectedID = nil; viewerID = nil }
            if !restoredCamera { restoredCamera = true; if PreviewLibrary.enabled || isProject { fitAll() } else { restoreCameraOrFit() } }
            updateGallery()
        }
    }

    func mapMoved(_ rect: MKMapRect, galleryRect: MKMapRect? = nil) {
        let world = MKMapRect.world.width
        if restoredCamera && !PreviewLibrary.enabled && !isProject { UserDefaults.standard.set([rect.minX, rect.minY, rect.width, rect.height], forKey: "camera") }
        let area = galleryRect ?? rect
        let next = AtlasRect(x: area.minX / world, y: area.minY / world, width: area.width / world, height: area.height / world)
        guard viewport != next else { return }
        viewport = next
        if selection == nil { updateGallery() }
    }

    func chooseArea(center: AtlasPoint, radius: Double) {
        selectionCenter = center; selectionRadius = radius
        selection = AtlasRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        selectionToken += 1
        selectedID = nil
        updateGallery()
    }

    func clearArea() {
        selection = nil; selectionCenter = nil; selectedID = nil; selectionToken += 1
        updateGallery()
    }

    private func updateGallery() {
        guard let area = selection ?? viewport else { return }
        queryTask?.cancel()
        let generation = queryGeneration.advance()
        let index = index, center = selectionCenter, radius = selectionRadius
        queryTask = Task {
            let start = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                var result = index.query(area)
                if let center {
                    result = result.filter {
                        guard let p = $0.point else { return false }
                        let dx = min(abs(p.x - center.x).truncatingRemainder(dividingBy: 1), 1 - abs(p.x - center.x).truncatingRemainder(dividingBy: 1))
                        return dx * dx + pow(p.y - center.y, 2) <= radius * radius
                    }
                }
                return (result, GallerySection.group(result))
            }.value
            guard !Task.isCancelled, queryGeneration.accepts(generation) else { return }
            if gallery != result.0 { gallery = result.0; gallerySections = result.1; galleryRevision += 1 }
            queryMilliseconds = Double(start.duration(to: .now).components.attoseconds) / 1e15 + Double(start.duration(to: .now).components.seconds) * 1000
            if let id = viewerID, !result.0.contains(where: { $0.id == id }) { viewerID = nil }
        }
    }

    func select(_ photo: PhotoRecord) { selectedID = photo.id }
    func open(_ photo: PhotoRecord) { selectedID = photo.id; viewerID = photo.id }
    func moveViewer(_ offset: Int) {
        guard let i = gallery.firstIndex(where: { $0.id == viewerID }) else { return }
        let next = i + offset
        guard gallery.indices.contains(next) else { return }
        viewerID = gallery[next].id; selectedID = viewerID
    }

    func fitAll() {
        guard !index.photos.isEmpty else { return }
        let points = index.photos.compactMap(\.point)
        let world = MKMapRect.world.width
        let ys = points.map(\.y), xs = points.map(\.x).sorted()
        var start = xs.first!, span = xs.last! - xs.first!
        // Remove the largest empty longitude gap to fit libraries straddling the date line.
        var largestGap = 1 - span
        for i in 1..<xs.count where xs[i] - xs[i - 1] > largestGap {
            largestGap = xs[i] - xs[i - 1]; start = xs[i]; span = 1 - largestGap
        }
        let minY = ys.min()!, maxY = ys.max()!
        cameraRequest = MKMapRect(x: start * world, y: minY * world, width: max(span * world, 3000), height: max((maxY - minY) * world, 3000))
        cameraFitsContent = true; cameraToken += 1
        clearArea()
    }

    private func restoreCameraOrFit() {
        if let a = UserDefaults.standard.array(forKey: "camera") as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 {
            cameraRequest = MKMapRect(x: a[0], y: a[1], width: a[2], height: a[3]); cameraFitsContent = false; cameraToken += 1
        } else { fitAll() }
    }

    func goTo(_ item: MKMapItem) {
        clearArea()
        let region = MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        let tl = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2, longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let br = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2, longitude: region.center.longitude + region.span.longitudeDelta / 2))
        cameraRequest = MKMapRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y); cameraFitsContent = true; cameraToken += 1
    }

    func requestExport(save: Bool) { saveExport = save; isExporting = true; exportRequest += 1 }
    func finishExport(_ image: NSImage?, error: String?) {
        isExporting = false
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            exportError = error ?? L10n.text("Couldn’t create the map image. Try again."); return
        }
        if saveExport {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "libhm.png"
            if panel.runModal() == .OK, let url = panel.url {
                do { try png.write(to: url); notice = L10n.text("Map saved") } catch { exportError = L10n.format("Couldn’t save the map: %@", error.localizedDescription) }
            }
        } else {
            let item = NSPasteboardItem(); item.setData(png, forType: .png)
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item]); notice = L10n.text("Map copied")
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
    }
}
