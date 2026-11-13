import XCTest
import MapKit

final class MapViewportTests: XCTestCase {
    func testCanvasProjectionIncludesNativeTitleBarInsetAndBothViewOrigins() throws {
        for flipped in [false, true] {
            let center = CGPoint(x: 500, y: 350 + (flipped ? -16 : 16))
            let direction: Double = flipped ? 1 : -1
            let rect = try XCTUnwrap(MapCanvasProjection.rect(bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
                center: MKMapPoint(x: 20_000, y: 40_000), step: MKMapSize(width: 500, height: 500),
                projectedCenter: center, projectedX: CGPoint(x: 750, y: center.y),
                projectedY: CGPoint(x: center.x, y: center.y + direction * 250), flipped: flipped))
            XCTAssertEqual(rect.minX, 19_000, accuracy: 0.0001)
            XCTAssertEqual(rect.minY, 39_332, accuracy: 0.0001)
            XCTAssertEqual(rect.width, 2000, accuracy: 0.0001)
            XCTAssertEqual(rect.height, 1400, accuracy: 0.0001)
        }
    }

    func testCanvasProjectionKeepsUnwrappedLongitudeAndRejectsCollapsedViews() throws {
        let world = MKMapRect.world.width
        let center = MKMapPoint(x: world + 1000, y: world / 2)
        let rect = try XCTUnwrap(MapCanvasProjection.rect(bounds: CGRect(x: 0, y: 0, width: 1000, height: 700),
            center: center, step: MKMapSize(width: 500, height: 500), projectedCenter: CGPoint(x: 500, y: 350),
            projectedX: CGPoint(x: 750, y: 350), projectedY: CGPoint(x: 500, y: 100), flipped: false))
        XCTAssertEqual(rect.minX, world, accuracy: 0.0001)
        XCTAssertEqual(rect.maxX, world + 2000, accuracy: 0.0001)
        XCTAssertNil(MapCanvasProjection.rect(bounds: .zero, center: center, step: MKMapSize(width: 1, height: 1),
            projectedCenter: .zero, projectedX: .zero, projectedY: .zero, flipped: false))
    }

    private var layout: MapViewportLayout {
        MapViewportLayout(size: CGSize(width: 1000, height: 700),
            panel: CGRect(x: 12, y: 42, width: 340, height: 638),
            controls: CGRect(x: 942, y: 42, width: 42, height: 172),
            legend: CGRect(x: 820, y: 648, width: 164, height: 26))
    }

    func testFreeAreaUsesAllFourChromeEdgesWithNegativePadding() {
        XCTAssertEqual(layout.screenRect, CGRect(x: 340, y: 30, width: 614, height: 630))
        let frame = layout.screenRect
        XCTAssertTrue(frame.contains(CGPoint(x: 345, y: 300)), "12 points beneath the panel remain included")
        XCTAssertFalse(frame.contains(CGPoint(x: 330, y: 300)))
        XCTAssertFalse(frame.contains(CGPoint(x: 960, y: 300)))
        XCTAssertFalse(frame.contains(CGPoint(x: 600, y: 20)))
        XCTAssertFalse(frame.contains(CGPoint(x: 600, y: 670)))
    }

    func testPanelResizeCollapseAndLegendRemovalChangeTheArea() {
        var changed = layout
        changed.panel?.size.width = 420
        XCTAssertEqual(changed.screenRect.minX, 420)
        changed.panel = CGRect(x: 12, y: 42, width: 420, height: 68)
        changed.galleryExpanded = false
        XCTAssertEqual(changed.screenRect.minX, 0)
        XCTAssertEqual(changed.screenRect.minY, 98)
        changed.legend = nil
        XCTAssertEqual(changed.screenRect.maxY, 700)
        changed.size.width = 800
        changed.controls?.origin.x = 742
        XCTAssertEqual(changed.screenRect.maxX, 754)
    }

    func testProjectEdgesStayInsideTheMapAndScaleIndependentlyOfRetina() {
        var project = layout
        project.panel?.origin.y = 12
        project.controls?.origin.y = 12
        XCTAssertEqual(project.screenRect.minY, 0)
        let camera = MKMapRect(x: 1000, y: 2000, width: 20_000, height: 14_000)
        let area = project.galleryRect(in: camera)
        XCTAssertEqual(area.minX, 7800, accuracy: 0.001)
        XCTAssertEqual(area.minY, 2000, accuracy: 0.001)
        XCTAssertEqual(area.maxX, 20_080, accuracy: 0.001)
        XCTAssertEqual(area.maxY, 15_200, accuracy: 0.001)
    }

    func testInsetQueryCrossesDateLineWithoutIncludingHiddenPoints() {
        let world = MKMapRect.world.width
        let chrome = MapViewportLayout(size: CGSize(width: 1000, height: 700),
            panel: CGRect(x: 12, y: 12, width: 340, height: 668),
            controls: CGRect(x: 942, y: 12, width: 42, height: 172))
        let rect = chrome.galleryRect(in: MKMapRect(x: world * 0.98, y: world * 0.49, width: world * 0.04, height: world * 0.02))
        func photo(_ id: String, _ lon: Double) -> PhotoRecord {
            PhotoRecord(id: id, latitude: 0, longitude: lon, date: nil, modified: nil, width: 100, height: 100, favorite: false)
        }
        let index = SpatialIndex(photos: [photo("east", 179), photo("west", -179), photo("under-panel", 174), photo("under-controls", -173)])
        let area = AtlasRect(x: rect.minX / world, y: rect.minY / world, width: rect.width / world, height: rect.height / world)
        XCTAssertEqual(Set(index.query(area).map(\.id)), ["east", "west"])
    }

    @MainActor
    func testLayoutChangesUpdateGalleryButPreservePinnedSelectionAndFullCamera() async throws {
        let world = MKMapRect.world.width
        let camera = MKMapRect.world
        let central = MKMapRect(x: world * 0.4, y: world * 0.4, width: world * 0.2, height: world * 0.2)
        func photo(_ id: String, _ longitude: Double) -> PhotoRecord {
            PhotoRecord(id: id, latitude: 0, longitude: longitude, date: nil, modified: nil, width: 100, height: 100, favorite: false)
        }
        let visible = photo("visible", 0), covered = photo("covered", -120)
        let model = AppModel(isProject: true, libraryLoader: { LibrarySnapshot(photos: [visible, covered], albums: []) })
        defer { model.stop() }
        await model.load()
        try await waitFor { model.mappedCount == 2 }
        let requestedCamera = model.cameraRequest
        model.mapMoved(camera, galleryRect: central)
        try await waitFor { model.gallery.map(\.id) == ["visible"] }
        model.chooseArea(center: covered.point!, radius: 0.01)
        try await waitFor { model.gallery.map(\.id) == ["covered"] }
        model.select(covered)
        model.mapMoved(camera, galleryRect: camera)
        XCTAssertEqual(model.gallery.map(\.id), ["covered"])
        XCTAssertEqual(model.selectedID, "covered")
        model.clearArea()
        try await waitFor { model.gallery.count == 2 }
        XCTAssertEqual(model.cameraRequest?.minX, requestedCamera?.minX)
        XCTAssertEqual(model.cameraRequest?.minY, requestedCamera?.minY)
        XCTAssertEqual(model.cameraRequest?.width, requestedCamera?.width)
        XCTAssertEqual(model.cameraRequest?.height, requestedCamera?.height)
        model.mapMoved(camera, galleryRect: central)
        try await waitFor { model.gallery.map(\.id) == ["visible"] }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
