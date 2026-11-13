import AppKit
import SwiftUI
import Photos

struct PhotoGallery: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let collection = AtlasCollectionView(frame: NSRect(x: 0, y: 0, width: 350, height: 600))
        collection.autoresizingMask = [.width]
        collection.collectionViewLayout = Self.makeLayout()
        collection.wantsLayer = true
        collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(PhotoCell.self, forItemWithIdentifier: .init("photo"))
        collection.register(DateHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: .init("date"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.onOpen = { [weak c = context.coordinator] in c?.openSelection() }
        collection.onEscape = { [weak model] in model?.clearArea() }
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2; collection.addGestureRecognizer(doubleClick)
        let scroll = GalleryScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = collection
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.collection = collection
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak c = context.coordinator] _ in
            MainActor.assumeIsolated { c?.schedulePreheat() }
        }
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: proposal.height ?? 600)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let token = coordinator.observer { NotificationCenter.default.removeObserver(token) }
        coordinator.preheatTask?.cancel()
        scroll.documentView = nil
        PhotoImageLoader.shared.preheat(ids: [])
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.galleryRevision != model.galleryRevision || c.revision != model.revision {
            c.revision = model.revision; c.galleryRevision = model.galleryRevision
            c.sections = model.gallerySections
            c.collection?.reloadData()
        }
        if let id = model.selectedID, let path = c.path(for: id), c.collection?.selectionIndexPaths != [path] {
            c.collection?.selectionIndexPaths = [path]
        } else if model.selectedID == nil { c.collection?.selectionIndexPaths = [] }
        c.schedulePreheat()
        if c.viewerWasOpen && model.viewerID == nil {
            c.collection?.window?.makeFirstResponder(c.collection)
        }
        c.viewerWasOpen = model.viewerID != nil
    }

    static func makeLayout() -> NSCollectionViewCompositionalLayout {
        NSCollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(2, Int(width / 130))
            let side = max(1, floor((width - 24 - CGFloat(columns - 1) * 4) / CGFloat(columns)))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                subitem: item, count: columns)
            group.interItemSpacing = .fixed(4)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 4
            section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 14, trailing: 12)
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(34)),
                elementKind: NSCollectionView.elementKindSectionHeader, alignment: .top)
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: AppModel
        weak var collection: NSCollectionView?
        var sections: [GallerySection] = []
        var galleryRevision = -1
        var revision = -1
        var observer: NSObjectProtocol?
        var heated: [String] = []
        var viewerWasOpen = false
        var preheatTask: Task<Void, Never>?
        init(model: AppModel) { self.model = model }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].photos.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: .init("photo"), for: indexPath) as! PhotoCell
            cell.configure(sections[indexPath.section].photos[indexPath.item])
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("date"), for: indexPath) as! DateHeader
            let section = sections[indexPath.section]
            header.title = section.date == .distantPast ? L10n.text("Unknown date") : L10n.date(section.date, time: false)
            header.photoCount = L10n.number(section.photos.count)
            return header
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            if let p = indexPaths.first, sections.indices.contains(p.section), sections[p.section].photos.indices.contains(p.item) { model.select(sections[p.section].photos[p.item]) }
            collectionView.window?.makeFirstResponder(collectionView)
        }
        func path(for id: String) -> IndexPath? {
            for (s, section) in sections.enumerated() {
                if let i = section.photos.firstIndex(where: { $0.id == id }) { return IndexPath(item: i, section: s) }
            }
            return nil
        }
        func schedulePreheat() {
            guard preheatTask == nil else { return }
            preheatTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(32))
                guard !Task.isCancelled, let self else { return }
                self.preheatTask = nil
                self.preheat()
            }
        }
        func preheat() {
            guard let collection, let layout = collection.collectionViewLayout else { return }
            // Query neighboring rows geometrically, including the next/previous day.
            let viewport = collection.visibleRect
            let area = viewport.insetBy(dx: 0, dy: -viewport.height * 0.75)
            let paths = layout.layoutAttributesForElements(in: area)
                .filter { $0.representedElementCategory == .item }.compactMap(\.indexPath)
                .filter { sections.indices.contains($0.section) && sections[$0.section].photos.indices.contains($0.item) }
            let ids = Set(paths).sorted().prefix(120).map { sections[$0.section].photos[$0.item].id }
            if ids != heated { heated = ids; PhotoImageLoader.shared.preheat(ids: ids) }
        }
        func openSelection() {
            if let photo = model.gallery.first(where: { $0.id == model.selectedID }) ?? model.gallery.first { model.open(photo) }
        }
        @objc func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let collection, let p = collection.indexPathForItem(at: recognizer.location(in: collection)), sections.indices.contains(p.section), sections[p.section].photos.indices.contains(p.item) else { return }
            model.open(sections[p.section].photos[p.item])
        }
    }
}

@MainActor
final class GalleryScrollView: NSScrollView {
    private let fade = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = fade
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(0.5, 24 / max(1, bounds.height))
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
    }
}

@MainActor
final class AtlasCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onOpen?() }
        else if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class CoverImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class PhotoCell: NSCollectionViewItem {
    private let photoView = CoverImageView()
    private let loading = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let retry = NSButton(title: L10n.text("Retry"), target: nil, action: nil)
    private var request: PHImageRequestID?
    private var generation = 0
    private var photo: PhotoRecord?
    override var isSelected: Bool { didSet { view.layer?.borderWidth = isSelected ? 3 : 0 } }
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        view.layer?.cornerRadius = 6; view.layer?.masksToBounds = true; view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.alignment = .center
        loading.style = .spinning; loading.controlSize = .small; loading.isDisplayedWhenStopped = false
        retry.target = self; retry.action = #selector(reload); retry.bezelStyle = .rounded; retry.isHidden = true
        for child in [photoView, status, retry, loading] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            photoView.leadingAnchor.constraint(equalTo: view.leadingAnchor), photoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            photoView.topAnchor.constraint(equalTo: view.topAnchor), photoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor), status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor), loading.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            retry.centerXAnchor.constraint(equalTo: view.centerXAnchor), retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4)
        ])
    }
    func configure(_ photo: PhotoRecord) {
        self.photo = photo
        view.setAccessibilityLabel(L10n.format(photo.favorite ? "Photo, %@, favorite" : "Photo, %@", L10n.date(photo.date)))
        reload()
    }
    @objc private func reload() {
        guard let photo else { return }
        PhotoImageLoader.shared.cancel(request); generation += 1
        let token = generation
        photoView.image = nil; status.stringValue = ""; retry.isHidden = true; loading.startAnimation(nil)
        request = PhotoImageLoader.shared.request(photo.id, size: PhotoImageLoader.thumbnailSize, contentMode: .aspectFill, progress: { [weak self] progress in
            guard let self, generation == token, photoView.image == nil else { return }
            status.stringValue = "iCloud · \(L10n.percent(progress))"
        }) { [weak self] image, error, _ in
            guard let self, generation == token else { return }
            if let image { photoView.image = image; status.stringValue = ""; loading.stopAnimation(nil) }
            if error != nil && image == nil { loading.stopAnimation(nil); status.stringValue = L10n.text("Unavailable"); retry.isHidden = false }
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse(); generation += 1
        PhotoImageLoader.shared.cancel(request); request = nil; photo = nil; photoView.image = nil; loading.stopAnimation(nil)
    }
}

@MainActor
final class DateHeader: NSView, NSCollectionViewElement {
    private let dateLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    var title = "" { didSet { updateText() } }
    var photoCount = "" { didSet { updateText() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        dateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [dateLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateText() {
        dateLabel.stringValue = title
        countLabel.stringValue = photoCount
        setAccessibilityLabel(L10n.format("%@, photos: %@", title, photoCount))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        title = ""
        photoCount = ""
    }
}
