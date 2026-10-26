import XCTest
import MapKit

final class AtlasTests: XCTestCase {
    func photo(_ id: String, _ lat: Double? = 0, _ lon: Double? = 0, date: Date? = .now, favorite: Bool = false) -> PhotoRecord {
        PhotoRecord(id: id, latitude: lat, longitude: lon, date: date, modified: nil, width: 100, height: 100, favorite: favorite)
    }

    func testSpatialQueryMatchesBruteForce() {
        let photos = (0..<4000).map { photo("\($0)", Double(($0 * 37) % 160) - 80, Double(($0 * 71) % 360) - 180) }
        let index = SpatialIndex(photos: photos)
        for i in 0..<30 {
            let rect = AtlasRect(x: Double(i) / 40, y: 0.2, width: 0.13, height: 0.4)
            XCTAssertEqual(Set(index.query(rect).map(\.id)), Set(photos.filter { rect.contains($0.point!) }.map(\.id)))
        }
    }

    func testDateLineAndDuplicateCoordinates() {
        let photos = [photo("east", 0, 179.9), photo("west", 0, -179.9), photo("middle", 0, 0)] + (0..<2000).map { photo("duplicate\($0)", 0, 179.9) }
        let index = SpatialIndex(photos: photos)
        let result = index.query(AtlasRect(x: 0.99, y: 0.49, width: 0.02, height: 0.02))
        XCTAssertEqual(result.count, 2002)
        XCTAssertFalse(result.contains { $0.id == "middle" })
        let density = index.density(in: AtlasRect(x: 0.99, y: 0.49, width: 0.02, height: 0.02), resolution: 0.00001)
        XCTAssertEqual(density.reduce(0) { $0 + $1.count }, 2002)
    }

    func testInvalidAndMissingCoordinatesAreExcluded() {
        let index = SpatialIndex(photos: [photo("missing", nil, nil), photo("bad", .nan, 0), photo("outside", 95, 0), photo("valid")])
        XCTAssertEqual(index.query(AtlasRect(x: 0, y: 0, width: 1, height: 1)).map(\.id), ["valid"])
    }

    func testFiltersComposeAndDateEndIsExclusive() {
        let start = Date(timeIntervalSince1970: 1000), end = Date(timeIntervalSince1970: 2000)
        let filters = PhotoFilters(start: start, end: end, albumID: "album", favoritesOnly: true)
        XCTAssertTrue(filters.matches(photo("yes", date: start, favorite: true), albumIDs: ["yes"]))
        XCTAssertFalse(filters.matches(photo("yes", date: end, favorite: true), albumIDs: ["yes"]))
        XCTAssertFalse(filters.matches(photo("yes", date: nil, favorite: true), albumIDs: ["yes"]))
        XCTAssertFalse(filters.matches(photo("yes", date: start, favorite: false), albumIDs: ["yes"]))
        XCTAssertFalse(filters.matches(photo("no", date: start, favorite: true), albumIDs: ["yes"]))
    }

    func testOldRequestsCannotReplaceNewResults() {
        var generation = RequestGeneration()
        let old = generation.advance(), current = generation.advance()
        XCTAssertFalse(generation.accepts(old))
        XCTAssertTrue(generation.accepts(current))
    }

    func testTileHaloMatchesContinuousRaster() throws {
        let index = SpatialIndex(photos: [photo("edge", 0, 0), photo("near", 0.1, 0.05), photo("far", 40, 100)])
        let whole = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02), width: 256, height: 256, scale: 1))
        let left = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.49, y: 0.49, width: 0.01, height: 0.02), width: 128, height: 256, scale: 1))
        let right = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.50, y: 0.49, width: 0.01, height: 0.02), width: 128, height: 256, scale: 1))
        let all = whole.dataProvider!.data! as Data, a = left.dataProvider!.data! as Data, b = right.dataProvider!.data! as Data
        for y in 0..<256 {
            XCTAssertEqual(all.subdata(in: y * 1024..<y * 1024 + 512), a.subdata(in: y * 512..<(y + 1) * 512))
            XCTAssertEqual(all.subdata(in: y * 1024 + 512..<(y + 1) * 1024), b.subdata(in: y * 512..<(y + 1) * 512))
        }
    }

    func testDensityTransparencyAndCoincidentWeight() throws {
        let rect = AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02)
        let empty = try XCTUnwrap(DensityRaster.image(index: SpatialIndex(photos: []), rect: rect, width: 64, height: 64, scale: 1))
        XCTAssertTrue((empty.dataProvider!.data! as Data).allSatisfy { $0 == 0 })
        let single = try XCTUnwrap(DensityRaster.image(index: SpatialIndex(photos: [photo("a")]), rect: rect, width: 64, height: 64, scale: 1))
        let dense = try XCTUnwrap(DensityRaster.image(index: SpatialIndex(photos: (0..<40).map { photo("\($0)") }), rect: rect, width: 64, height: 64, scale: 1))
        let i = (32 * 64 + 32) * 4
        let a = single.dataProvider!.data! as Data, b = dense.dataProvider!.data! as Data
        XCTAssertGreaterThan(b[i], a[i]); XCTAssertGreaterThanOrEqual(b[i + 3], a[i + 3])
    }

    func testSparseLocationsAreVioletAndDenseCentersAreTranslucentPink() throws {
        let rect = AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02)
        func center(_ records: [PhotoRecord]) throws -> [UInt8] {
            let image = try XCTUnwrap(DensityRaster.image(index: SpatialIndex(photos: records), rect: rect, width: 64, height: 64, scale: 1))
            let data = image.dataProvider!.data! as Data
            let offset = (32 * 64 + 32) * 4
            return Array(data[offset..<offset + 4])
        }
        let sparse = try center([photo("single")])
        let dense = try center((0..<100).map { photo("\($0)") })
        XCTAssertGreaterThan(sparse[2], sparse[0])
        XCTAssertGreaterThan(dense[0], dense[2])
        XCTAssertGreaterThan(dense[2], dense[1])
        XCTAssertGreaterThan(dense[3], 0)
        XCTAssertLessThan(dense[3], 145, "Map labels must remain visible through dense centers")
    }

    func testCoordinateChangeWithSameAssetCount() {
        let original = SpatialIndex(photos: [photo("same-id", 0, 0)])
        let updated = SpatialIndex(photos: [photo("same-id", 50, 50)])
        let area = AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02)
        XCTAssertEqual(original.query(area).count, 1)
        XCTAssertTrue(updated.query(area).isEmpty)
    }

    func testGalleryGroupsDatesAndUnknownDates() {
        let day = Calendar.current.startOfDay(for: Date())
        let records = [photo("late", date: day.addingTimeInterval(100)), photo("early", date: day), photo("older", date: day.addingTimeInterval(-100)), photo("unknown", date: nil)]
        let sections = GallerySection.group(records)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].photos.map(\.id), ["late", "early"])
        XCTAssertEqual(sections.last?.date, .distantPast)
    }

    func testPanDoesNotRenormalizeHeatmap() throws {
        let records = (0..<300).map { photo("\($0)", Double($0 % 11) / 100, Double($0 % 23) / 100) }
        let index = SpatialIndex(photos: records)
        let before = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02), width: 256, height: 256, scale: 1))
        let after = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.495, y: 0.49, width: 0.02, height: 0.02), width: 256, height: 256, scale: 1))
        let a = before.dataProvider!.data! as Data, b = after.dataProvider!.data! as Data
        for y in 0..<256 {
            XCTAssertEqual(a.subdata(in: y * 1024 + 256..<(y + 1) * 1024), b.subdata(in: y * 1024..<y * 1024 + 768))
        }
    }

    func testCacheEvictsLeastRecentlyUsedAndRejectsOversizedValues() {
        let cache = MemoryCache<String>(limit: 100)
        cache.insert("first", for: "a", cost: 40)
        cache.insert("second", for: "b", cost: 40)
        XCTAssertEqual(cache.value(for: "a"), "first")
        cache.insert("third", for: "c", cost: 40)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.chargedBytes, 80)
        cache.insert("oversized", for: "large", cost: 101)
        XCTAssertNil(cache.value(for: "large"))
        XCTAssertLessThanOrEqual(cache.chargedBytes, 100)
        cache.removeAll()
        XCTAssertEqual(cache.chargedBytes, 0)
    }

    func testInvalidatedTileRequestsCompleteWithCancellation() {
        let overlay = DensityOverlay(index: SpatialIndex(photos: [photo("a")]))
        overlay.invalidate()
        let done = expectation(description: "Cancelled tile returns promptly")
        done.assertForOverFulfill = true
        overlay.loadTile(at: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)) { data, error in
            XCTAssertNil(data)
            XCTAssertTrue(error is CancellationError)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testDenseClusterTailDoesNotClipAtCoreRadius() throws {
        let index = SpatialIndex(photos: (0..<12_500).map { photo("\($0)") })
        let image = try XCTUnwrap(DensityRaster.image(index: index, rect: AtlasRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02), width: 256, height: 256, scale: 1))
        let pixels = image.dataProvider!.data! as Data
        XCTAssertGreaterThan(pixels[(128 * 256 + 158) * 4 + 3], 0)
        XCTAssertEqual(pixels[(128 * 256 + 208) * 4 + 3], 0)
    }

    func testHundredThousandPhotoQueryLatency() {
        let photos = PerformanceReport.syntheticPhotos(count: 100_000)
        let report = PerformanceReport.measure(photos: photos)
        print("ATLAS_BENCHMARK \(report)")
        XCTAssertLessThan(report.queryP95, 250)
        XCTAssertLessThan(report.galleryP95, 250)
        XCTAssertLessThan(report.densityP95, 250)
    }
}
