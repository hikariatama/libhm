import AppKit
@preconcurrency import MapKit
import SwiftUI
import OSLog

struct PhotoMapView: NSViewRepresentable {
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false; map.isPitchEnabled = false
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 50, maxCenterCoordinateDistance: 100_000_000)
        map.showsZoomControls = false; map.showsScale = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.buttonMask = 1
        map.addGestureRecognizer(click)
        context.coordinator.map = map
        let coordinator = context.coordinator
        if let heatmap = HeatmapMetalView(map: map) {
            heatmap.autoresizingMask = [.width, .height]
            heatmap.onFailure = { [weak coordinator, weak map] in
                guard let coordinator, let map else { return }
                coordinator.gpuFailed = true; coordinator.heatmapView?.isHidden = true; coordinator.heatmapView?.stop()
                if coordinator.model.showHeatmap { coordinator.installFallback(on: map) }
            }
            map.addSubview(heatmap)
            coordinator.heatmapView = heatmap
        }
        return map
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MKMapView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.density?.invalidate()
        coordinator.heatmapView?.stop()
        coordinator.moveTask?.cancel()
        coordinator.cameraTask?.cancel()
        coordinator.snapshotter?.cancel()
        map.delegate = nil
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.viewportLayout != model.mapViewportLayout {
            c.viewportLayout = model.mapViewportLayout
            c.scheduleViewportUpdate(map)
        }
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if map.appearance?.name != appearance { map.appearance = NSAppearance(named: appearance) }
        if c.satellite != model.satellite {
            c.satellite = model.satellite
            if model.satellite { map.preferredConfiguration = MKImageryMapConfiguration() }
            else {
                let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            }
        }
        if c.revision != model.revision || c.heatmap != model.showHeatmap {
            c.revision = model.revision; c.heatmap = model.showHeatmap
            if let overlay = c.density { overlay.invalidate(); map.removeOverlay(overlay) }
            c.density = nil
            c.heatmapView?.isHidden = !model.showHeatmap || c.gpuFailed
            if !model.showHeatmap { c.heatmapView?.cameraDidStop() }
            if model.showHeatmap {
                if c.gpuFailed || c.heatmapView == nil { c.installFallback(on: map) }
                else { c.heatmapView?.setPhotos(model.index.photos); c.heatmapView?.cameraChanged() }
            }
        }
        if c.cameraToken != model.cameraToken, let rect = model.cameraRequest {
            c.cameraToken = model.cameraToken
            c.cameraTask?.cancel()
            let fit = model.cameraFitsContent, animate = c.cameraToken > 1
            let leftInset = model.showGallery ? model.mapPanelInset : 40
            c.cameraTask = Task { @MainActor [weak map] in
                try? await Task.sleep(for: .milliseconds(animate ? 1 : 120))
                guard !Task.isCancelled, let map else { return }
                let global = rect.width > MKMapRect.world.width * 0.5
                map.setVisibleMapRect(rect, edgePadding: fit && !global ? NSEdgeInsets(top: 60, left: leftInset, bottom: 40, right: 70) : NSEdgeInsets(), animated: animate)

            }
        }
        if c.zoomToken != model.zoomToken {
            c.zoomToken = model.zoomToken
            let camera = map.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance /= model.zoomFactor
            map.setCamera(camera, animated: true)
        }
        if c.selectionToken != model.selectionToken {
            c.selectionToken = model.selectionToken
            if let circle = c.selectionCircle { map.removeOverlay(circle) }
            c.selectionCircle = nil
            if let center = model.selectionCenter {
                let world = MKMapRect.world.width
                let coordinate = MKMapPoint(x: center.x * world, y: center.y * world).coordinate
                let circle = MKCircle(center: coordinate, radius: model.selectionRadius * world * MKMetersPerMapPointAtLatitude(coordinate.latitude))
                c.selectionCircle = circle; map.addOverlay(circle, level: .aboveLabels)
            }
        }
        if c.selectedID != model.selectedID {
            c.selectedID = model.selectedID
            map.removeAnnotations(map.annotations)
            if let photo = model.selectedPhoto, let lat = photo.latitude, let lon = photo.longitude {
                let annotation = MKPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                annotation.title = L10n.date(photo.date)
                map.addAnnotation(annotation)
            }
        }
        if c.exportToken != model.exportRequest {
            c.exportToken = model.exportRequest
            c.capture(map: map, dark: colorScheme == .dark)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let model: AppModel
        weak var map: MKMapView?
        var density: DensityOverlay?
        var heatmapView: HeatmapMetalView?
        var gpuFailed = false
        var selectionCircle: MKCircle?
        var revision = -1
        var heatmap = false
        var satellite: Bool?
        var zoomToken = 0
        var cameraToken = 0
        var selectionToken = -1
        var exportToken = 0
        var selectedID: String?
        var moveTask: Task<Void, Never>?
        var cameraTask: Task<Void, Never>?
        var snapshotter: MKMapSnapshotter?
        var viewportLayout = MapViewportLayout()
        private let diagnostics = ProcessInfo.processInfo.arguments.contains("--heatmap-diagnostics")
        private var renderStarts = 0
        private var renderFinishes = 0
        private var incompleteRenders = 0
        private var loadStarts = 0
        private var loadFailures = 0

        init(model: AppModel) { self.model = model }

        func installFallback(on map: MKMapView) {
            guard density == nil else { return }
            let overlay = DensityOverlay(index: model.index)
            density = overlay; map.addOverlay(overlay, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .controlAccentColor; renderer.fillColor = .controlAccentColor.withAlphaComponent(0.08); renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "selected-photo")
            view.markerTintColor = .controlAccentColor
            view.glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: L10n.text("Selected photo"))
            view.canShowCallout = true
            view.clusteringIdentifier = nil
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            heatmapView?.cameraChanged()
            scheduleViewportUpdate(mapView)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) { heatmapView?.cameraWillMove() }

        func scheduleViewportUpdate(_ mapView: MKMapView) {
            guard moveTask == nil else { return }
            moveTask = Task { [weak self, weak mapView] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let self, let mapView else { return }
                moveTask = nil
                publishViewport(mapView)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            heatmapView?.cameraDidStop()
            moveTask?.cancel(); moveTask = nil
            publishViewport(mapView)
            if diagnostics {
                Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "MapRendering").notice("Camera settled: heatmap=\(self.model.showHeatmap) renderStarts=\(self.renderStarts) renderFinishes=\(self.renderFinishes) incomplete=\(self.incompleteRenders) loadStarts=\(self.loadStarts) loadFailures=\(self.loadFailures)")
            }
        }

        func mapViewWillStartRenderingMap(_ mapView: MKMapView) { if diagnostics { renderStarts += 1 } }
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if diagnostics { renderFinishes += 1; if !fullyRendered { incompleteRenders += 1 } }
        }
        func mapViewWillStartLoadingMap(_ mapView: MKMapView) { if diagnostics { loadStarts += 1 } }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
            loadFailures += 1
            let error = error as NSError
            Logger(subsystem: "com.hikariatama.PhotoAtlas", category: "MapRendering").error("MapKit loading failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }

        private func publishViewport(_ mapView: MKMapView) {
            guard viewportLayout.size.width > 0, viewportLayout.size.height > 0 else { return }
            let camera = mapView.visibleMapRect
            model.mapMoved(camera, galleryRect: viewportLayout.galleryRect(in: mapView.canvasMapRect))
        }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let map else { return }
            let location = recognizer.location(in: map)
            var hit = map.hitTest(location)
            while let view = hit {
                if view is MKAnnotationView || view is NSButton { return }
                hit = view.superview
            }
            let point = MKMapPoint(map.convert(location, toCoordinateFrom: map))
            let world = MKMapRect.world.width
            model.chooseArea(center: AtlasPoint(x: point.x / world, y: point.y / world), radius: 28 * map.canvasMapRect.width / max(1, map.bounds.width) / world)
        }

        func capture(map: MKMapView, dark: Bool) {
            let options = MKMapSnapshotter.Options()
            options.camera = map.camera; options.size = map.bounds.size
            options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if model.satellite { options.preferredConfiguration = MKImageryMapConfiguration() }
            else {
                let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll; options.preferredConfiguration = config
            }
            let rect = map.visibleMapRect, world = MKMapRect.world.width
            let area = AtlasRect(x: rect.minX / world, y: rect.minY / world, width: rect.width / world, height: rect.height / world)
            let index = model.index, showHeat = model.showHeatmap
            let photo = model.selectedPhoto
            let snapshotter = MKMapSnapshotter(options: options)
            self.snapshotter = snapshotter
            Task {
                do {
                    let snapshot = try await snapshotter.start()
                    let size = options.size
                    let heat = await Task.detached(priority: .userInitiated) {
                        showHeat ? DensityRaster.image(index: index, rect: area, width: Int(size.width * 2), height: Int(size.height * 2), scale: 2) : nil
                    }.value
                    let image = NSImage(size: size)
                    image.lockFocus()
                    snapshot.image.draw(in: CGRect(origin: .zero, size: size))
                    if let heat, let ctx = NSGraphicsContext.current?.cgContext { ctx.draw(heat, in: CGRect(origin: .zero, size: size)) }
                    if let photo, let lat = photo.latitude, let lon = photo.longitude {
                        let p = snapshot.point(for: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        NSColor.controlAccentColor.setFill()
                        let marker = NSBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)); marker.fill()
                        NSColor.white.setStroke(); marker.lineWidth = 2; marker.stroke()
                    }
                    image.unlockFocus()
                    model.finishExport(image, error: nil)
                } catch { model.finishExport(nil, error: error.localizedDescription) }
                self.snapshotter = nil
            }
        }
    }
}
