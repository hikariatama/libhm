import Accelerate
import AppKit
@preconcurrency import MapKit

/// A geographic density field. Tile borders use the same impulse grid and a full kernel halo.
enum DensityRaster {
    static let radius = 18.0

    static func image(index: SpatialIndex, rect: AtlasRect, width: Int, height: Int, scale: Double) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // Keep the faint Gaussian tail beyond the core. Truncating at 3 sigma
        // creates square, opaque edges when thousands of photos share a location.
        let halo = Int(ceil(radius * 3 * scale)) + 2
        let w = width + halo * 2, h = height + halo * 2
        let stepX = rect.width / Double(width), stepY = rect.height / Double(height)
        let expanded = AtlasRect(x: rect.x - Double(halo) * stepX, y: rect.y - Double(halo) * stepY,
                                 width: Double(w) * stepX, height: Double(h) * stepY)
        let samples = index.density(in: expanded, resolution: min(stepX, stepY) * 0.5)
        var input = [Float](repeating: 0, count: w * h)
        for sample in samples {
            let x = (sample.point.x - rect.x) / stepX + Double(halo) - 0.5
            let y = (sample.point.y - rect.y) / stepY + Double(halo) - 0.5
            let ix = Int(floor(x)), iy = Int(floor(y))
            let fx = Float(x - Double(ix)), fy = Float(y - Double(iy))
            for dy in 0...1 {
                for dx in 0...1 where ix + dx >= 0 && ix + dx < w && iy + dy >= 0 && iy + dy < h {
                    input[(iy + dy) * w + ix + dx] += Float(sample.count) * (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy)
                }
            }
        }
        let r = Int(ceil(radius * 3 * scale)), sigma = radius * scale / 3
        let kernel = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        var output = [Float](repeating: 0, count: w * h)
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(data: src.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var target = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                kernel.withUnsafeBufferPointer { k in
                    _ = vImageSepConvolve_PlanarF(&source, &target, nil, 0, 0, k.baseAddress!, UInt32(k.count), k.baseAddress!, UInt32(k.count), 0, 0, vImage_Flags(kvImageBackgroundColorFill))
                }
            }
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = max(0, output[(y + halo) * w + x + halo])
                guard value > 0.003 else { continue }
                let t = min(1, log1p(value) / log1p(40))
                let alpha = min(0.52, Double(value) * 0.85)
                let color = color(Double(t))
                let i = (y * width + x) * 4
                rgba[i] = UInt8(color.0 * alpha * 255)
                rgba[i + 1] = UInt8(color.1 * alpha * 255)
                rgba[i + 2] = UInt8(color.2 * alpha * 255)
                rgba[i + 3] = UInt8(alpha * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func color(_ t: Double) -> (Double, Double, Double) {
        // Sparse locations stay violet; overlapping samples reveal cyan, yellow and pink.
        // Fixed stops keep a place the same color when the camera pans.
        let stops: [(position: Double, rgb: (Double, Double, Double))] = [
            (0, (0.60, 0.30, 0.88)),
            (0.24, (0.65, 0.38, 0.92)),
            (0.42, (0.36, 0.83, 0.85)),
            (0.61, (1.00, 0.89, 0.46)),
            (0.80, (0.98, 0.54, 0.76)),
            (1, (0.98, 0.54, 0.76))
        ]
        let i = min(stops.count - 2, max(0, (stops.firstIndex { $0.position > t } ?? stops.count) - 1))
        let a = stops[i], b = stops[i + 1]
        let f = (t - a.position) / (b.position - a.position)
        return (a.rgb.0 + (b.rgb.0 - a.rgb.0) * f,
                a.rgb.1 + (b.rgb.1 - a.rgb.1) * f,
                a.rgb.2 + (b.rgb.2 - a.rgb.2) * f)
    }
}

final class DensityOverlay: MKTileOverlay, @unchecked Sendable {
    let index: SpatialIndex
    private let cache = MemoryCache<Data>(limit: 96 * 1024 * 1024)
    private let workers = OperationQueue()
    private typealias TileReply = @Sendable (Data?, (any Error)?) -> Void
    private let lock = NSLock()
    private var pending: [String: [TileReply]] = [:]
    private var invalidated = false

    init(index: SpatialIndex) {
        self.index = index
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0; maximumZ = 21
        canReplaceMapContent = false
        workers.maxConcurrentOperationCount = 2
        workers.qualityOfService = .userInitiated
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let n = 1 << path.z
        let x = ((path.x % n) + n) % n
        let scale = max(1, min(2, path.contentScaleFactor))
        let key = "\(path.z)/\(x)/\(path.y)/\(scale)"
        if let data = cache.value(for: key) { result(data, nil); return }
        lock.lock()
        if invalidated {
            lock.unlock(); result(nil, CancellationError()); return
        }
        if pending[key] != nil {
            pending[key]!.append(result); lock.unlock(); return
        }
        pending[key] = [result]
        lock.unlock()
        workers.addOperation { [self] in
            let rect = AtlasRect(x: Double(x) / Double(n), y: Double(path.y) / Double(n), width: 1 / Double(n), height: 1 / Double(n))
            let size = Int(256 * scale)
            guard let image = DensityRaster.image(index: index, rect: rect, width: size, height: size, scale: scale),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                finish(key: key, data: nil, error: NSError(domain: "PhotoAtlas.Rendering", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Couldn’t render the map overlay.")]))
                return
            }
            cache.insert(data, for: key, cost: size * size * 4 + data.count)
            finish(key: key, data: data, error: nil)
        }
    }

    private func finish(key: String, data: Data?, error: (any Error)?) {
        lock.lock(); let replies = pending.removeValue(forKey: key) ?? []; lock.unlock()
        for reply in replies { reply(data, error) }
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let replies = pending.values.flatMap { $0 }
        pending.removeAll()
        lock.unlock()
        workers.cancelAllOperations()
        cache.removeAll()
        for reply in replies { reply(nil, CancellationError()) }
    }
}
