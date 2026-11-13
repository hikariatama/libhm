import Foundation

struct HeatmapSample: Sendable {
    let point: AtlasPoint
    let count: Int
}

/// Packed quadtree ranges let the GPU process visible points without walking the library per frame.
final class HeatmapPointIndex: Sendable {
    private struct Coordinate: Hashable { let x: Double; let y: Double }
    private final class Node: Sendable {
        let bounds: AtlasRect
        let range: Range<Int>
        let children: [Node]
        init(bounds: AtlasRect, range: Range<Int>, children: [Node]) {
            self.bounds = bounds; self.range = range; self.children = children
        }
    }
    let samples: [HeatmapSample]
    let photoCount: Int
    private let root: Node

    init(photos: [PhotoRecord]) throws {
        try Task.checkCancellation()
        var counts: [Coordinate: Int] = [:]
        for (i, photo) in photos.enumerated() {
            if i % 1024 == 0 { try Task.checkCancellation() }
            guard let p = photo.point else { continue }
            let x = p.x == 1 ? 0 : p.x
            counts[Coordinate(x: x, y: p.y), default: 0] += 1
        }
        var ordered: [HeatmapSample] = []
        ordered.reserveCapacity(counts.count)
        let entries = counts.map { HeatmapSample(point: AtlasPoint(x: $0.key.x, y: $0.key.y), count: $0.value) }
        photoCount = entries.reduce(0) { $0 + $1.count }
        root = try Self.pack(entries, bounds: AtlasRect(x: 0, y: 0, width: 1, height: 1), depth: 0, into: &ordered)
        samples = ordered
    }

    private static func pack(_ entries: [HeatmapSample], bounds: AtlasRect, depth: Int, into ordered: inout [HeatmapSample]) throws -> Node {
        try Task.checkCancellation()
        let start = ordered.count
        guard entries.count > 128, depth < 22 else {
            ordered.append(contentsOf: entries)
            return Node(bounds: bounds, range: start..<ordered.count, children: [])
        }
        let half = bounds.width / 2
        var groups = [[HeatmapSample]](repeating: [], count: 4)
        for sample in entries {
            let column = sample.point.x >= bounds.x + half ? 1 : 0
            let row = sample.point.y >= bounds.y + half ? 1 : 0
            groups[row * 2 + column].append(sample)
        }
        let children = try groups.enumerated().compactMap { n, group -> Node? in
            guard !group.isEmpty else { return nil }
            return try pack(group, bounds: AtlasRect(x: bounds.x + Double(n % 2) * half,
                y: bounds.y + Double(n / 2) * half, width: half, height: half), depth: depth + 1, into: &ordered)
        }
        return Node(bounds: bounds, range: start..<ordered.count, children: children)
    }

    /// Leaf ranges may include neighboring points; the shader culls them before accumulation.
    func ranges(in rect: AtlasRect) -> [Range<Int>] {
        var result: [Range<Int>] = []
        collect(root, rect: rect, into: &result)
        return result
    }
    private func collect(_ node: Node, rect: AtlasRect, into result: inout [Range<Int>]) {
        guard !node.range.isEmpty, node.bounds.intersects(rect) else { return }
        if node.children.isEmpty || (rect.x <= node.bounds.x && rect.y <= node.bounds.y && rect.x + rect.width >= node.bounds.x + node.bounds.width && rect.y + rect.height >= node.bounds.y + node.bounds.height) {
            if let last = result.last, last.upperBound == node.range.lowerBound {
                result[result.count - 1] = last.lowerBound..<node.range.upperBound
            } else { result.append(node.range) }
        } else { for child in node.children { collect(child, rect: rect, into: &result) } }
    }
}

struct HeatmapDispatchSpan {
    var start: UInt32
    var count: UInt32
    var originX: Float
    var originXLow: Float
}

struct HeatmapProjection: Sendable {
    let camera: AtlasRect
    let size: CGSize

    func spans(index: HeatmapPointIndex, halo: Double = DensityRaster.radius * 3) -> [HeatmapDispatchSpan] {
        guard size.width > 0, size.height > 0, camera.width > 0, camera.height > 0 else { return [] }
        let dx = halo / size.width * camera.width, dy = halo / size.height * camera.height
        let area = AtlasRect(x: camera.x - dx, y: camera.y - dy, width: camera.width + 2 * dx, height: camera.height + 2 * dy)
        var spans: [HeatmapDispatchSpan] = []
        for world in Int(floor(area.x))...Int(floor(area.x + area.width)) {
            let local = AtlasRect(x: area.x - Double(world), y: area.y, width: area.width, height: area.height)
            let origin = camera.x - Double(world), high = Float(origin), low = Float(origin - Double(high))
            for range in index.ranges(in: local) {
                for start in stride(from: range.lowerBound, to: range.upperBound, by: 1024) {
                    spans.append(HeatmapDispatchSpan(start: UInt32(start), count: UInt32(min(1024, range.upperBound - start)), originX: high, originXLow: low))
                }
            }
        }
        return spans
    }
}
