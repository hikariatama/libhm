import AppKit
import XCTest

final class GalleryLayoutTests: XCTestCase {
    @MainActor
    func testHeadersAndCellsStayInTheirSectionsDuringScrollAndResize() async throws {
        let gallery = Fixture(counts: (0..<80).map { [20, 1, 21, 4][$0 % 4] })
        defer { gallery.window.close() }
        for (width, y) in [(340, 0), (340, 760), (340, 4200), (340, 12000),
                           (300, 4200), (420, 1700), (340, 200), (340, 0)] {
            gallery.window.setContentSize(NSSize(width: width, height: 440))
            await gallery.settle()
            gallery.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            gallery.scroll.reflectScrolledClipView(gallery.scroll.contentView)
            await gallery.settle()
            try gallery.checkVisibleGeometry()
        }
        XCTAssertLessThan(gallery.source.createdItems, 120, "Scrolling must reuse cells")
        XCTAssertLessThan(gallery.source.createdHeaders, 30, "Scrolling must reuse date headers")
        print("Gallery scroll fixture: \(gallery.source.counts.reduce(0, +)) photos, \(gallery.source.createdItems) cell instances, \(gallery.source.createdHeaders) header instances")
        let nextDate = gallery.collection.collectionViewLayout!.layoutAttributesForSupplementaryView(
            ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1))!.frame.minY
        gallery.scroll.contentView.scroll(to: NSPoint(x: 0, y: nextDate - 100))
        await gallery.settle()
        try gallery.checkVisibleGeometry()
        try gallery.capture()
    }

    @MainActor
    func testReloadAtScrolledOffsetDoesNotLeaveOldDateHeaders() async throws {
        let gallery = Fixture(counts: Array(repeating: 5, count: 100))
        defer { gallery.window.close() }
        await gallery.settle()
        gallery.scroll.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        await gallery.settle()
        for counts in [[1, 20, 1, 21], Array(repeating: 1, count: 120), [2, 3]] {
            gallery.source.revision += 1
            gallery.source.counts = counts
            gallery.collection.reloadData()
            await gallery.settle()
            gallery.scroll.contentView.scroll(to: .zero)
            await gallery.settle()
            try gallery.checkVisibleGeometry()
        }
    }

    @MainActor
    func testHeaderReuseClearsTextAndKeepsLongLabelsInsideItsBounds() {
        let header = DateHeader(frame: NSRect(x: 0, y: 0, width: 180, height: 34))
        header.title = "Очень длинная дата, 25 октября 2026 года"
        header.photoCount = "100 000"
        header.layoutSubtreeIfNeeded()
        let fields = header.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy { header.bounds.contains($0.frame) })
        XCTAssertFalse(fields[0].frame.intersects(fields[1].frame))
        header.prepareForReuse()
        XCTAssertTrue(fields.allSatisfy { $0.stringValue.isEmpty })
    }

    @MainActor
    func testNativeScrollFadeKeepsIts24PointEdgesAfterResize() async throws {
        let gallery = Fixture(counts: [1, 20, 1, 21])
        defer { gallery.window.close() }
        for height in [440, 280, 700] {
            gallery.window.setContentSize(NSSize(width: 340, height: height))
            await gallery.settle()
            let fade = try XCTUnwrap(gallery.scroll.layer?.mask as? CAGradientLayer)
            XCTAssertEqual(fade.frame, gallery.scroll.bounds)
            let locations = try XCTUnwrap(fade.locations)
            XCTAssertEqual(locations[1].doubleValue * Double(height), 24, accuracy: 0.01)
            XCTAssertEqual((1 - locations[2].doubleValue) * Double(height), 24, accuracy: 0.01)
        }
    }

    @MainActor
    private final class Fixture {
        let source: Source
        let collection = AtlasCollectionView(frame: NSRect(x: 0, y: 0, width: 340, height: 600))
        let scroll = GalleryScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 440))
        let window: NSWindow

        init(counts: [Int]) {
            _ = NSApplication.shared
            source = Source(counts: counts)
            window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 340, height: 440),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.contentView = scroll
            collection.autoresizingMask = [.width]
            collection.wantsLayer = true
            collection.backgroundColors = [.clear]
            collection.collectionViewLayout = PhotoGallery.makeLayout()
            collection.register(Item.self, forItemWithIdentifier: .init("fixture"))
            collection.register(DateHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                withIdentifier: .init("date"))
            collection.dataSource = source
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.documentView = collection
            window.orderBack(nil)
        }

        func settle() async {
            for _ in 0..<3 {
                scroll.layoutSubtreeIfNeeded()
                collection.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func checkVisibleGeometry(file: StaticString = #filePath, line: UInt = #line) throws {
            let layout = try XCTUnwrap(collection.collectionViewLayout)
            let visible = collection.indexPathsForVisibleItems()
            XCTAssertFalse(visible.isEmpty, file: file, line: line)
            for path in visible {
                let item = try XCTUnwrap(collection.item(at: path))
                let frame = try XCTUnwrap(layout.layoutAttributesForItem(at: path)).frame
                XCTAssertEqual(item.view.frame, frame, file: file, line: line)
                XCTAssertEqual(item.representedObject as? String, source.itemID(path), file: file, line: line)
                XCTAssertEqual(frame.width, frame.height, accuracy: 1, file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxX, scroll.contentSize.width, file: file, line: line)
            }
            let kind = NSCollectionView.elementKindSectionHeader
            let paths = collection.indexPathsForVisibleSupplementaryElements(ofKind: kind)
            for path in paths {
                let header = try XCTUnwrap(collection.supplementaryView(forElementKind: kind, at: path) as? DateHeader)
                let frame = try XCTUnwrap(layout.layoutAttributesForSupplementaryView(ofKind: kind, at: path)).frame
                XCTAssertEqual(header.frame, frame, file: file, line: line)
                XCTAssertEqual(header.title, source.headerTitle(path.section), file: file, line: line)
                XCTAssertEqual(header.photoCount, String(source.counts[path.section]), file: file, line: line)
                for itemPath in visible {
                    let itemFrame = try XCTUnwrap(layout.layoutAttributesForItem(at: itemPath)).frame
                    XCTAssertFalse(frame.intersects(itemFrame), "Header intersects a photo", file: file, line: line)
                }
            }
            let headers = collection.visibleSupplementaryViews(ofKind: kind)
                .filter { $0.frame.intersects(collection.visibleRect) }
            XCTAssertEqual(Set(headers.map { ObjectIdentifier($0) }).count, headers.count, file: file, line: line)
        }

        func capture() throws {
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/libhm-gallery-layout.png"))
        }
    }

    @MainActor
    private final class Source: NSObject, NSCollectionViewDataSource {
        var counts: [Int]
        var revision = 0
        var createdItems = 0
        var createdHeaders = 0
        private var items = Set<ObjectIdentifier>()
        private var headers = Set<ObjectIdentifier>()
        init(counts: [Int]) { self.counts = counts }
        func itemID(_ path: IndexPath) -> String { "\(revision):\(path.section):\(path.item)" }
        func headerTitle(_ section: Int) -> String { "Day \(section + 1) · \(revision)" }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { counts.count }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { counts[section] }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("fixture"), for: indexPath)
            if items.insert(ObjectIdentifier(item)).inserted { createdItems += 1 }
            item.representedObject = itemID(indexPath)
            item.view.layer?.backgroundColor = NSColor(calibratedHue: CGFloat(indexPath.section % 8) / 8,
                saturation: 0.4, brightness: 0.6, alpha: 1).cgColor
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("date"), for: indexPath) as! DateHeader
            if headers.insert(ObjectIdentifier(header)).inserted { createdHeaders += 1 }
            header.title = headerTitle(indexPath.section)
            header.photoCount = String(counts[indexPath.section])
            return header
        }
    }

    @MainActor
    private final class Item: NSCollectionViewItem {
        override func loadView() {
            view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = 6
        }
    }
}
