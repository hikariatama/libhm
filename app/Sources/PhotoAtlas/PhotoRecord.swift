import Foundation

struct PhotoRecord: Identifiable, Sendable, Equatable {
    let id: String
    let latitude: Double?
    let longitude: Double?
    let date: Date?
    let modified: Date?
    let width: Int
    let height: Int
    let favorite: Bool

    var point: AtlasPoint? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return AtlasPoint(latitude: latitude, longitude: longitude)
    }
}

struct AlbumRecord: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let photoIDs: Set<String>
}

struct PhotoFilters: Equatable, Sendable {
    var start: Date?
    var end: Date?
    var albumID: String?
    var favoritesOnly = false
    var isActive: Bool { start != nil || end != nil || albumID != nil || favoritesOnly }

    func matches(_ photo: PhotoRecord, albumIDs: Set<String>?) -> Bool {
        if favoritesOnly && !photo.favorite { return false }
        if let albumIDs, !albumIDs.contains(photo.id) { return false }
        if let start, photo.date.map({ $0 < start }) ?? true { return false }
        if let end, photo.date.map({ $0 >= end }) ?? true { return false }
        return true
    }
}

struct AtlasPoint: Sendable, Equatable {
    let x: Double
    let y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(latitude: Double, longitude: Double) {
        x = (longitude + 180) / 360
        let lat = min(85.05112878, max(-85.05112878, latitude)) * .pi / 180
        y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2
    }
}

struct AtlasRect: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    func contains(_ point: AtlasPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
    func intersects(_ other: AtlasRect) -> Bool {
        x <= other.x + other.width && x + width >= other.x && y <= other.y + other.height && y + height >= other.y
    }
}

struct WeightedPoint: Sendable {
    let point: AtlasPoint
    let count: Int
}

// Immutable after construction. Each node stores a density aggregate as well as its children.
final class SpatialIndex: Sendable {
    private final class Node: Sendable {
        let bounds: AtlasRect
        let count: Int
        let center: AtlasPoint
        let entries: [Int]
        let children: [Node]

        init(indices: [Int], points: [AtlasPoint], bounds: AtlasRect, depth: Int) {
            self.bounds = bounds
            count = indices.count
            center = AtlasPoint(x: indices.reduce(0) { $0 + points[$1].x } / Double(max(1, indices.count)),
                                y: indices.reduce(0) { $0 + points[$1].y } / Double(max(1, indices.count)))
            if indices.count <= 32 || depth >= 20 {
                entries = indices; children = []; return
            }
            let half = bounds.width / 2
            var groups = [[Int]](repeating: [], count: 4)
            for i in indices {
                let column = points[i].x >= bounds.x + half ? 1 : 0
                let row = points[i].y >= bounds.y + half ? 1 : 0
                groups[row * 2 + column].append(i)
            }
            entries = []
            children = groups.enumerated().compactMap { n, group in
                guard !group.isEmpty else { return nil }
                return Node(indices: group, points: points,
                            bounds: AtlasRect(x: bounds.x + Double(n % 2) * half,
                                              y: bounds.y + Double(n / 2) * half, width: half, height: half), depth: depth + 1)
            }
        }
    }

    let photos: [PhotoRecord]
    private let points: [AtlasPoint]
    private let root: Node

    init(photos: [PhotoRecord]) {
        let valid = photos.sorted(by: Self.dateOrder).compactMap { photo -> (PhotoRecord, AtlasPoint)? in
            guard let point = photo.point else { return nil }; return (photo, point)
        }
        self.photos = valid.map(\.0)
        points = valid.map(\.1)
        root = Node(indices: Array(valid.indices), points: points,
                    bounds: AtlasRect(x: 0, y: 0, width: 1, height: 1), depth: 0)
    }

    func query(_ rect: AtlasRect) -> [PhotoRecord] {
        var found = Set<Int>()
        // The map can display copies of the world on either side of the date line.
        let first = Int(floor(rect.x)), last = Int(floor(rect.x + min(rect.width, 1)))
        for world in first...max(first, last) {
            let local = AtlasRect(x: rect.x - Double(world), y: rect.y, width: min(rect.width, 1), height: rect.height)
            collect(root, rect: local, into: &found)
        }
        return found.sorted().map { photos[$0] }
    }

    private func collect(_ node: Node, rect: AtlasRect, into found: inout Set<Int>) {
        guard node.bounds.intersects(rect) else { return }
        for i in node.entries where rect.contains(points[i]) { found.insert(i) }
        for child in node.children { collect(child, rect: rect, into: &found) }
    }

    func density(in rect: AtlasRect, resolution: Double) -> [WeightedPoint] {
        var output: [WeightedPoint] = []
        for shift in -1...1 {
            let local = AtlasRect(x: rect.x - Double(shift), y: rect.y, width: rect.width, height: rect.height)
            aggregate(root, rect: local, resolution: resolution, shift: Double(shift), output: &output)
        }
        return output
    }

    private func aggregate(_ node: Node, rect: AtlasRect, resolution: Double, shift: Double, output: inout [WeightedPoint]) {
        guard node.count > 0, node.bounds.intersects(rect) else { return }
        if node.bounds.width <= resolution {
            output.append(WeightedPoint(point: AtlasPoint(x: node.center.x + shift, y: node.center.y), count: node.count))
        } else if node.children.isEmpty {
            for i in node.entries where rect.contains(points[i]) {
                output.append(WeightedPoint(point: AtlasPoint(x: points[i].x + shift, y: points[i].y), count: 1))
            }
        } else {
            for child in node.children { aggregate(child, rect: rect, resolution: resolution, shift: shift, output: &output) }
        }
    }

    static func dateOrder(_ a: PhotoRecord, _ b: PhotoRecord) -> Bool {
        if a.date == b.date { return a.id < b.id }
        return (a.date ?? .distantPast) > (b.date ?? .distantPast)
    }
}

// Used by background UI requests to reject a result computed for an older viewport/filter.
struct RequestGeneration: Sendable {
    private(set) var value = 0
    mutating func advance() -> Int { value += 1; return value }
    func accepts(_ candidate: Int) -> Bool { candidate == value }
}

struct GallerySection: Sendable {
    let date: Date
    var photos: [PhotoRecord]

    static func group(_ photos: [PhotoRecord]) -> [GallerySection] {
        var result: [GallerySection] = []
        var interval: DateInterval?
        let calendar = Calendar.current
        for photo in photos {
            let date = photo.date ?? .distantPast
            if let interval, interval.contains(date), !result.isEmpty {
                result[result.count - 1].photos.append(photo)
            } else {
                interval = calendar.dateInterval(of: .day, for: date)
                let day = photo.date == nil ? Date.distantPast : interval?.start ?? date
                if result.last?.date == day { result[result.count - 1].photos.append(photo) }
                else { result.append(GallerySection(date: day, photos: [photo])) }
            }
        }
        return result
    }
}
