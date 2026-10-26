import Foundation

struct PerformanceReport: Codable, Sendable {
    let count: Int
    let buildMilliseconds: Double
    let queryP95: Double
    let galleryP95: Double
    let densityP95: Double
    let legacyDensityP95: Double
    let coldTileP95: Double
    let querySamples: Int

    static func syntheticPhotos(count: Int) -> [PhotoRecord] {
        (0..<count).map { i in
            // Repeatable dense cities and dispersed outliers, including both sides of the date line.
            let city = i % 8
            let lat = Double([-33, 35, 51, 21, 40, 0, 0, 55][city]) + Double((i * 37) % 1000) / 10000
            let lon = Double([151, 139, 0, 105, -74, 179, -179, 37][city]) + Double((i * 71) % 1000) / 10000
            return PhotoRecord(id: "fixture-\(i)", latitude: lat, longitude: lon, date: Date(timeIntervalSince1970: Double(i) * 1000), modified: nil, width: 4000, height: 3000, favorite: i % 4 == 0)
        }
    }

    static func measure(photos: [PhotoRecord]) -> PerformanceReport {
        let buildStart = ContinuousClock.now
        let index = SpatialIndex(photos: photos)
        let build = elapsed(buildStart)
        let points = index.photos.compactMap(\.point)
        guard !points.isEmpty else { return PerformanceReport(count: 0, buildMilliseconds: build, queryP95: 0, galleryP95: 0, densityP95: 0, legacyDensityP95: 0, coldTileP95: 0, querySamples: 0) }
        var query: [Double] = [], gallery: [Double] = [], density: [Double] = [], legacy: [Double] = [], tiles: [Double] = []
        var checksum = 0
        for i in 0..<90 {
            let p = points[(i * 7919) % points.count]
            let span = [0.0005, 0.005, 0.05, 1.0][i % 4]
            let area = AtlasRect(x: p.x - span / 2, y: p.y - span / 2, width: span, height: span)
            var start = ContinuousClock.now
            let selected = index.query(area); checksum += selected.count; query.append(elapsed(start))
            checksum += GallerySection.group(selected).count; gallery.append(elapsed(start))
            start = .now
            checksum += index.density(in: area, resolution: span / 1024).count; density.append(elapsed(start))
            start = .now
            // The original renderer scanned all records and rebuilt screen buckets on every draw.
            var buckets: [LegacyCell: LegacyCluster] = [:]
            let cell = span * 14 / 1024
            for point in points where area.contains(point) {
                let key = LegacyCell(x: Int(floor(point.x / cell)), y: Int(floor(point.y / cell)))
                buckets[key, default: LegacyCluster()].add(point)
            }
            checksum += buckets.values.sorted { $0.count < $1.count }.count; legacy.append(elapsed(start))
            if i < 12 {
                start = .now
                _ = DensityRaster.image(index: index, rect: area, width: 512, height: 512, scale: 2)
                tiles.append(elapsed(start))
            }
        }
        precondition(checksum >= 0)
        return PerformanceReport(count: photos.count, buildMilliseconds: build, queryP95: percentile(query), galleryP95: percentile(gallery), densityP95: percentile(density), legacyDensityP95: percentile(legacy), coldTileP95: percentile(tiles), querySamples: query.count)
    }

    static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    static func percentile(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.sorted()[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    }

    static func saveDiagnostics(photos: [PhotoRecord]) async {
        await Task.detached(priority: .utility) {
            let reports = ["library": measure(photos: photos), "synthetic100k": measure(photos: syntheticPhotos(count: 100_000))]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let folder = URL.cachesDirectory.appending(path: "PhotoAtlas")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try encoder.encode(reports).write(to: folder.appending(path: "benchmark.json"), options: .atomic)
            } catch { print("Photo Atlas benchmark: \(error.localizedDescription)") }
        }.value
    }
}

private struct LegacyCell: Hashable { let x: Int; let y: Int }
private struct LegacyCluster {
    var count = 0
    var totalX = 0.0
    var totalY = 0.0
    mutating func add(_ point: AtlasPoint) { count += 1; totalX += point.x; totalY += point.y }
}
