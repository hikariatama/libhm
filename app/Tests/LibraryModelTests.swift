import XCTest

final class LibraryModelTests: XCTestCase {
    private func photo(_ id: String) -> PhotoRecord {
        PhotoRecord(id: id, latitude: 16.06, longitude: 108.22, date: .now, modified: nil, width: 100, height: 100, favorite: true)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    func testEmbeddedLibraryRefreshAddsNewPhotosWithoutLosingPinnedSelection() async throws {
        let first = photo("first")
        var records = [first, photo("outside-project")]
        let model = AppModel(isProject: true, libraryLoader: { LibrarySnapshot(photos: records, albums: []) })
        defer { model.stop() }
        await model.load()
        try await waitFor { model.index.photos.count == 2 }
        XCTAssertTrue(model.isProject)
        XCTAssertNotNil(model.cameraRequest)
        model.chooseArea(center: first.point!, radius: 0.01)
        try await waitFor { model.gallery.count == 2 }
        model.select(first)
        records.append(photo("new-import"))
        model.refreshLibrary()
        try await waitFor { model.gallery.contains { $0.id == "new-import" } }
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertNotNil(model.selection)
        XCTAssertEqual(model.mappedCount, 3)
        records.removeAll { $0.id == first.id }
        model.refreshLibrary()
        try await waitFor { model.photos.count == 2 }
        XCTAssertNil(model.selectedID)
        XCTAssertNotNil(model.selection)
    }

    @MainActor
    func testStoppedLibraryLoadCannotReplaceNewerData() async throws {
        let old = photo("old"), current = photo("current")
        var pending: CheckedContinuation<LibrarySnapshot, Never>?
        var reads = 0
        let model = AppModel(isProject: true, libraryLoader: {
            reads += 1
            if reads == 1 { return await withCheckedContinuation { pending = $0 } }
            return LibrarySnapshot(photos: [current], albums: [])
        })
        defer { model.stop() }
        let loading = Task { await model.load() }
        try await waitFor { pending != nil }
        model.stop()
        await model.load()
        pending?.resume(returning: LibrarySnapshot(photos: [old], albums: []))
        await loading.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.photos.map(\.id), [current.id])
    }

    @MainActor
    func testEmbeddedLibraryCanRetryAfterAccessIsGranted() async {
        let first = photo("first")
        var allowed = false
        let model = AppModel(isProject: true, libraryLoader: {
            guard allowed else { throw PhotoLibraryError.accessDenied }
            return LibrarySnapshot(photos: [first], albums: [])
        })
        defer { model.stop() }
        await model.load()
        XCTAssertEqual(model.phase, .denied)
        XCTAssertTrue(model.photos.isEmpty)
        allowed = true
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.photos.map(\.id), [first.id])
    }
}
