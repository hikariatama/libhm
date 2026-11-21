import Foundation
import XCTest

private final class WorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var shouldRelease = false
    private var calls = 0
    var started: Bool { lock.withLock { didStart } }
    var released: Bool { lock.withLock { shouldRelease } }
    var count: Int { lock.withLock { calls } }
    func start() { lock.withLock { didStart = true } }
    func release() { lock.withLock { shouldRelease = true } }
    func countCall() { lock.withLock { calls += 1 } }
}

final class GalleryCancellationTests: XCTestCase {
    private let world = AtlasRect(x: 0, y: 0, width: 1, height: 1)
    private func records() -> [PhotoRecord] {
        (0..<256).map { i in
            PhotoRecord(id: "synthetic-\(i)", latitude: Double(i % 80), longitude: Double(i % 170),
                        date: Date(timeIntervalSince1970: Double(i * 86400)), modified: nil,
                        width: 100, height: 100, favorite: false)
        }
    }

    func testIndexConstructionChecksCancellationDuringWork() {
        var checks = 0
        XCTAssertThrowsError(try SpatialIndex(photos: records(), checkCancellation: {
            checks += 1
            if checks == 80 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 80)
    }

    func testQueryChecksCancellationDuringTraversal() {
        let index = SpatialIndex(photos: records())
        var checks = 0
        XCTAssertThrowsError(try index.query(world, checkCancellation: {
            checks += 1
            if checks == 20 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 20)
        XCTAssertEqual(index.query(world).count, 256)
    }

    func testGroupingChecksCancellationBetweenPhotos() {
        var checks = 0
        XCTAssertThrowsError(try GallerySection.group(records(), checkCancellation: {
            checks += 1
            if checks == 20 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 20)
    }

    private func waitForStart(_ probe: WorkProbe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(probe.started)
    }

    func testParentCancellationReachesRunningWorker() async throws {
        let probe = WorkProbe()
        let parent = Task {
            do {
                try await GalleryWorker.perform {
                    probe.start()
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline {
                        try Task.checkCancellation()
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        defer { parent.cancel() }
        try await waitForStart(probe)
        parent.cancel()
        let cancelled = await parent.value
        XCTAssertTrue(cancelled)
    }

    func testWorkerSerializesWorkAndSkipsCancelledQueuedRequests() async throws {
        let probe = WorkProbe()
        let first = Task {
            try await GalleryWorker.perform {
                probe.start()
                let deadline = Date().addingTimeInterval(5)
                while !probe.released && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
        defer { probe.release(); first.cancel() }
        try await waitForStart(probe)
        let queued = (0..<20).map { _ in
            Task {
                do {
                    try await GalleryWorker.perform { probe.countCall() }
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
        }
        // Give requests a chance to queue while the first synchronous job owns the actor.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.count, 0)
        queued.forEach { $0.cancel() }
        probe.release()
        try await first.value
        for request in queued {
            let cancelled = await request.value
            XCTAssertTrue(cancelled)
        }
        XCTAssertEqual(probe.count, 0)
    }
}
