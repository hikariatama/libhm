import AppKit
@preconcurrency import Photos

struct LibrarySnapshot: Sendable {
    let photos: [PhotoRecord]
    let albums: [AlbumRecord]
}

enum PhotoLibraryError: LocalizedError {
    case accessDenied
    case authorizationTimeout
    var errorDescription: String? {
        switch self {
        case .accessDenied: L10n.text("Allow access to your photo library in System Settings.")
        case .authorizationTimeout: L10n.text("Photos hasn’t answered the access request. Check the macOS permission dialog or open Privacy & Security → Photos in System Settings, then try again.")
        }
    }
}

@MainActor
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: (() -> Void)?
    private var observing = false
    private var generation = 0

    func start(requireFullAccess: Bool = false) async throws -> LibrarySnapshot {
        let token = generation
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = try await withCheckedThrowingContinuation { continuation in
                let reply = AuthorizationReply(continuation)
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { @Sendable status in
                    Task { @MainActor in reply.finish(.success(status)) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    reply.finish(.failure(PhotoLibraryError.authorizationTimeout))
                }
            }
        } else { status = current }
        guard status == .authorized || (!requireFullAccess && status == .limited) else { throw PhotoLibraryError.accessDenied }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let snapshot = await Self.scan()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        return snapshot
    }

    func stop() {
        generation += 1
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self); observing = false }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    nonisolated static func scan() async -> LibrarySnapshot {
        await Task.detached(priority: .userInitiated) {
            let assets = PHAsset.fetchAssets(with: .image, options: nil)
            var photos: [PhotoRecord] = []
            photos.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                let coordinate = asset.location?.coordinate
                photos.append(PhotoRecord(id: asset.localIdentifier,
                                          latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                                          date: asset.creationDate, modified: asset.modificationDate,
                                          width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite))
            }
            var albums: [AlbumRecord] = []
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let members = PHAsset.fetchAssets(in: collection, options: nil)
                var ids = Set<String>()
                members.enumerateObjects { asset, _, _ in
                    if asset.mediaType == .image { ids.insert(asset.localIdentifier) }
                }
                albums.append(AlbumRecord(id: collection.localIdentifier, title: collection.localizedTitle ?? L10n.text("Untitled album"), photoIDs: ids))
            }
            return LibrarySnapshot(photos: photos.sorted(by: SpatialIndex.dateOrder), albums: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }.value
    }
}

@MainActor
private final class AuthorizationReply {
    private var continuation: CheckedContinuation<PHAuthorizationStatus, any Error>?
    init(_ continuation: CheckedContinuation<PHAuthorizationStatus, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<PHAuthorizationStatus, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class PhotoImageLoader {
    static let shared = PhotoImageLoader()
    private let manager = PHCachingImageManager()
    private let cache = MemoryCache<NSImage>(limit: 96 * 1024 * 1024)
    private var preheated: [PHAsset] = []
    private var epoch = 0
    private var active: [UUID: PHImageRequestID] = [:]
    static let thumbnailSize = CGSize(width: 384, height: 384)


    private func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return options
    }

    @discardableResult
    func request(_ id: String, size: CGSize, contentMode: PHImageContentMode = .aspectFit, progress: @escaping (Double) -> Void = { _ in },
                 completion: @escaping (NSImage?, String?, Bool) -> Void) -> PHImageRequestID? {
        if PreviewLibrary.enabled && id.hasPrefix("fixture-") {
            if ProcessInfo.processInfo.arguments.contains("--image-error") { completion(nil, L10n.text("Sample download failed. Retry when online."), true) }
            else { completion(PreviewLibrary.image(id: id, size: CGSize(width: min(800, size.width), height: min(600, size.height))), nil, true) }
            return nil
        }
        let key = "\(id):\(Int(size.width))x\(Int(size.height)):\(contentMode.rawValue)"
        if let image = cache.value(for: key) { completion(image, nil, true); return nil }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        guard let asset else {
            completion(nil, L10n.text("This photo is no longer available."), true); return nil
        }
        let opts = options()
        let token = UUID(), requestEpoch = epoch
        opts.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor in
                guard let self, self.epoch == requestEpoch else { return }
                progress(value)
            }
        }
        let request = manager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: opts) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let error = (info?[PHImageErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if !degraded || cancelled { self.active.removeValue(forKey: token) }
                guard !cancelled, self.epoch == requestEpoch else { return }
                if let image, !degraded {
                    let cost = Int(size.width * size.height * 4)
                    self.cache.insert(image, for: key, cost: cost)
                }
                completion(image, error ?? (image == nil && !degraded ? L10n.text("Couldn’t load this photo. Check your connection and try again.") : nil), !degraded)
            }
        }
        active[token] = request
        return request
    }

    func cancel(_ id: PHImageRequestID?) {
        guard let id else { return }
        manager.cancelImageRequest(id)
        for token in active.filter({ $0.value == id }).keys { self.active.removeValue(forKey: token) }
    }

    func preheat(ids: [String]) {
        guard !PreviewLibrary.enabled else { return }
        manager.stopCachingImages(for: preheated, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: options())
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        preheated = (0..<result.count).map { result.object(at: $0) }
        manager.startCachingImages(for: preheated, targetSize: Self.thumbnailSize, contentMode: .aspectFill, options: options())
    }

    func invalidate() {
        epoch += 1
        for id in active.values { manager.cancelImageRequest(id) }
        active.removeAll()
        cache.removeAll()
        manager.stopCachingImagesForAllAssets()
        preheated = []
    }
}
