import Photos
import SwiftUI

@MainActor
@Observable
private final class ViewerImage {
    var image: NSImage?
    var displayedID: String?
    var progress: Double?
    var error: String?
    private var request: PHImageRequestID?
    private var generation = 0
    func load(_ photo: PhotoRecord) {
        cancel(); let token = generation
        error = nil; progress = nil
        request = PhotoImageLoader.shared.request(photo.id, size: CGSize(width: max(1, min(4096, photo.width)), height: max(1, min(4096, photo.height))), progress: { [weak self] value in
            guard let self, generation == token else { return }; progress = value
        }) { [weak self] image, error, final in
            guard let self, generation == token else { return }
            if let image { self.image = image; self.displayedID = photo.id }
            self.error = error
            if final { progress = nil }
        }
    }
    func cancel() { generation += 1; PhotoImageLoader.shared.cancel(request); request = nil }
}

struct PhotoViewer: View {
    let model: AppModel
    let photo: PhotoRecord
    @State private var loaded = ViewerImage()
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var info = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewerKeyboardContainer(focusToken: photo.id, handle: handleKey) {
        VStack(spacing: 0) {
            viewerControls
            GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image = loaded.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .id(loaded.displayedID).transition(.opacity)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(zoom * gestureZoom).offset(offset)
                        .gesture(MagnifyGesture().onChanged { value in gestureZoom = max(1 / zoom, min(8 / zoom, value.magnification)) }
                            .onEnded { value in setZoom(zoom * value.magnification); gestureZoom = 1 })
                        .simultaneousGesture(DragGesture().onChanged { value in
                            guard zoom > 1 else { return }
                            let fit = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                            let limitX = max(0, (image.size.width * fit * zoom - geometry.size.width) / 2)
                            let limitY = max(0, (image.size.height * fit * zoom - geometry.size.height) / 2)
                            offset = CGSize(width: min(limitX, max(-limitX, dragStart.width + value.translation.width)), height: min(limitY, max(-limitY, dragStart.height + value.translation.height)))
                        }.onEnded { _ in dragStart = offset })
                        .onTapGesture(count: 2) { if zoom > 1 { fit() } else { setZoom(2) } }
                }
                if let error = loaded.error {
                    AtlasUnavailableView(icon: "icloud.slash", title: L10n.text("Photo unavailable"), detail: error) {
                        Button(L10n.text("Retry")) { loaded.load(photo) }
                    }
                } else if loaded.image == nil {
                    AtlasLoadingView(title: L10n.text("Loading photo…"), progress: loaded.progress)
                }
            }.clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: loaded.displayedID)
                .overlay(alignment: .bottom) {
                    if loaded.image != nil, let progress = loaded.progress {
                        ProgressView(value: progress).frame(width: 140).padding(12)
                            .accessibilityLabel(L10n.format("Downloading from iCloud · %@", L10n.percent(progress)))
                    }
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onChange(of: photo.id, initial: true) { _, _ in fit(animated: false); loaded.load(photo) }
        .onChange(of: photo.modified) { _, _ in loaded.load(photo) }
        .onDisappear { loaded.cancel() }
        }
    }

    private var viewerControls: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 2) {
                    Text(L10n.viewerDate(photo.date)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(position).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: max(80, geometry.size.width - 440))
                HStack(spacing: 10) {
                    Button { close() } label: {
                        Image(systemName: "chevron.left").frame(width: 32, height: 32)
                    }.buttonStyle(.plain).atlasGlass(cornerRadius: 18)
                        .help(L10n.text("Back to map")).accessibilityLabel(L10n.text("Back to map"))
                    HStack(spacing: 6) {
                        iconButton("Zoom out", symbol: "minus") { setZoom(zoom / 1.4) }.disabled(zoom <= 1)
                        Slider(value: Binding(get: { Double(zoom) }, set: { setZoom(CGFloat($0), animated: false) }), in: 1...8)
                            .frame(width: 82).controlSize(.small).accessibilityLabel(L10n.text("Zoom"))
                        iconButton("Zoom in", symbol: "plus") { setZoom(zoom * 1.4) }.disabled(zoom >= 8)
                    }.padding(.horizontal, 5).atlasGlass(cornerRadius: 18)
                    Spacer()
                    HStack(spacing: 4) {
                        iconButton("Photo information", symbol: "info.circle") { info.toggle() }
                            .popover(isPresented: $info) { information }
                        if photo.favorite { Image(systemName: "heart.fill").frame(width: 30, height: 32).accessibilityLabel(L10n.text("Favorite")) }
                        #if !PHOTO_PROJECT_EXTENSION
                        iconButton("Toggle full screen", symbol: "arrow.up.left.and.arrow.down.right") { NSApp.keyWindow?.toggleFullScreen(nil) }
                        #endif
                    }.padding(.horizontal, 5).atlasGlass(cornerRadius: 18)
                }.buttonStyle(.plain).padding(.horizontal, 12)
            }.frame(maxHeight: .infinity)
        }.frame(height: 52)
    }

    private var information: some View {
        Form {
            LabeledContent(L10n.text("Date"), value: L10n.date(photo.date, complete: true))
            LabeledContent(L10n.text("Dimensions"), value: L10n.format("%@ × %@ pixels", L10n.number(photo.width), L10n.number(photo.height)))
            if let lat = photo.latitude, let lon = photo.longitude {
                LabeledContent(L10n.text("Location")) {
                    Text(String(format: "%.5f, %.5f", lat, lon)).textSelection(.enabled)
                }
            }
            if let modified = photo.modified { LabeledContent(L10n.text("Modified"), value: L10n.date(modified)) }
        }.formStyle(.columns).padding(20).frame(width: 380).fixedSize(horizontal: false, vertical: true)
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 32).contentShape(Rectangle()) }
            .help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
    private var position: String {
        guard let i = model.gallery.firstIndex(where: { $0.id == photo.id }) else { return "" }
        return L10n.format("%@ of %@", L10n.number(i + 1), L10n.number(model.gallery.count))
    }
    private func handleKey(_ command: ViewerKeyCommand) {
        switch command {
        case .previous: model.moveViewer(-1)
        case .next: model.moveViewer(1)
        case .close: if info { info = false } else { close() }
        case .zoomIn: setZoom(zoom * 1.4)
        case .zoomOut: setZoom(zoom / 1.4)
        case .fit: fit()
        case .information: info.toggle()
        }
    }
    private func close() { model.viewerID = nil }
    private func setZoom(_ value: CGFloat, animated: Bool = true) {
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.2) : nil) {
            zoom = min(8, max(1, value))
            if zoom == 1 { offset = .zero; dragStart = .zero }
        }
    }
    private func fit(animated: Bool = true) {
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.2) : nil) {
            zoom = 1; gestureZoom = 1; offset = .zero; dragStart = .zero
        }
    }
}
