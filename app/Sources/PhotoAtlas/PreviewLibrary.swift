import AppKit

/// Explicit opt-in fixtures for UI checks without modifying the user's Photos library or permissions.
enum PreviewLibrary {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--sample-library") }
    static var denied: Bool { ProcessInfo.processInfo.arguments.contains("--simulate-denied") }
    static func snapshot() -> LibrarySnapshot {
        if ProcessInfo.processInfo.arguments.contains("--empty-library") { return LibrarySnapshot(photos: [], albums: []) }
        let source = ProcessInfo.processInfo.arguments.contains("--heatmap-reference") ? neighborhoodPhotos() : PerformanceReport.syntheticPhotos(count: ProcessInfo.processInfo.arguments.contains("--large-library") ? 100_000 : 240)
        let noLocations = ProcessInfo.processInfo.arguments.contains("--no-locations")
        let photos = source.enumerated().map { i, photo in
            PhotoRecord(id: photo.id, latitude: noLocations ? nil : photo.latitude, longitude: noLocations ? nil : photo.longitude,
                        date: Date(timeIntervalSince1970: 1_750_000_000 - Double(i) * 3600), modified: nil,
                        width: 2400, height: 1600, favorite: photo.favorite)
        }.sorted(by: SpatialIndex.dateOrder)
        return LibrarySnapshot(photos: photos, albums: [AlbumRecord(id: "sample-album", title: L10n.text("Sample favorites"), photoIDs: Set(photos.filter(\.favorite).map(\.id)))])
    }

    /// Deterministic street-scale samples for checking merged fields and isolated points.
    private static func neighborhoodPhotos() -> [PhotoRecord] {
        var photos: [PhotoRecord] = []
        func add(_ lat: Double, _ lon: Double, count: Int) {
            for _ in 0..<count {
                let i = photos.count
                photos.append(PhotoRecord(id: "fixture-\(i)", latitude: lat, longitude: lon, date: nil,
                                          modified: nil, width: 2400, height: 1600, favorite: i % 7 == 0))
            }
        }
        for i in 0..<68 {
            let t = Double(i) / 67
            add(16.035 + t * 0.052, 108.222 + sin(t * 8) * 0.004, count: 1 + (i * 7) % 13)
            if i > 12 && i < 54 {
                add(16.035 + t * 0.052, 108.24 + cos(t * 11) * 0.003, count: 1 + (i * 11) % 9)
            }
        }
        for i in 0..<24 {
            let t = Double(i) / 23
            add(16.061 + sin(t * 5) * 0.001, 108.207 + t * 0.04, count: 2 + i % 7)
        }
        for i in 0..<35 {
            add(16.034 + Double((i * 17) % 53) * 0.001, 108.204 + Double((i * 13) % 45) * 0.001, count: 1)
        }
        add(16.067, 108.228, count: 180)
        return photos
    }

    @MainActor
    static func image(id: String, size: CGSize) -> NSImage {
        let number = Int(id.replacingOccurrences(of: "fixture-", with: "")) ?? 0
        let image = NSImage(size: size)
        image.lockFocus()
        let first = NSColor(calibratedHue: CGFloat(number % 12) / 12, saturation: 0.45, brightness: 0.75, alpha: 1)
        let second = NSColor(calibratedHue: CGFloat((number + 2) % 12) / 12, saturation: 0.6, brightness: 0.35, alpha: 1)
        NSGradient(starting: first, ending: second)?.draw(in: CGRect(origin: .zero, size: size), angle: -45)
        let text = L10n.format("Sample %@", L10n.number(number + 1)) as NSString
        text.draw(at: CGPoint(x: size.width * 0.1, y: size.height * 0.12), withAttributes: [.font: NSFont.systemFont(ofSize: max(12, size.width * 0.07), weight: .medium), .foregroundColor: NSColor.white])
        image.unlockFocus()
        return image
    }
}
