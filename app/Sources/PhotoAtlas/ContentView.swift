import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model: AppModel
    @State private var filtersOpen = false
    @State private var photosGuideOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel = AppModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            switch model.phase {
            case .preparing, .scanning:
                AtlasLoadingView(title: L10n.text("Reading your photo library"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                message(icon: "photo.badge.exclamationmark", title: L10n.text("Photo access is off"), detail: L10n.text("Allow libhm to read your library in System Settings.")) {
                    Button(L10n.text("Open System Settings"), action: model.openSettings)
                    Button(L10n.text("Try again")) { Task { await model.load() } }
                }
            case let .failed(error):
                message(icon: "exclamationmark.triangle", title: L10n.text("Couldn’t read the library"), detail: error) {
                    Button(L10n.text("Try again")) { Task { await model.load() } }
                    Button(L10n.text("Open System Settings"), action: model.openSettings)
                }
            case .ready:
                workspace.accessibilityHidden(model.viewerID != nil).allowsHitTesting(model.viewerID == nil)
            }
            if let photo = model.viewerPhoto {
                PhotoViewer(model: model, photo: photo).zIndex(2)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.viewerID != nil)
        .frame(minWidth: model.isProject ? 640 : 900, minHeight: model.isProject ? 440 : 600)
        .environment(\.locale, L10n.locale)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(\.showPhotosProjectGuide, { photosGuideOpen = true })
        .sheet(isPresented: $photosGuideOpen) { PhotosProjectGuide(isProject: model.isProject) }
        .task { await model.load() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.checkPermission() } }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).padding(12).atlasGlass(cornerRadius: 16).padding(12)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2))
                        model.notice = nil
                    }
            }
        }
        .alert(L10n.text("Couldn’t export the map"), isPresented: Binding(get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })) {
            Button(L10n.text("OK")) { model.exportError = nil }
        } message: { Text(model.exportError ?? "") }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let width: CGFloat = 340
            ZStack(alignment: .topLeading) {
                PhotoMapView(model: model).ignoresSafeArea()
                if model.mappedCount == 0 {
                    AtlasUnavailableView(icon: "location.slash",
                        title: L10n.text(model.filters.isActive ? "No matching photo locations" : "No photo locations found"),
                        detail: L10n.text(model.filters.isActive ? "Try different filters to see photo locations." : model.photos.isEmpty ? "Your photo library is empty." : "Photos without location data won’t appear on the map.")) {
                        if model.filters.isActive { Button(L10n.text("Reset filters")) { model.filters = PhotoFilters() } }
                    }.padding(.leading, model.showGallery ? width + 24 : 0)
                        .background(.background.opacity(0.85))
                }
                VStack(spacing: 0) {
                    panelHeader
                    if model.showGallery {
                        galleryContent
                        if PreviewLibrary.enabled { Text(L10n.text("Sample library")).font(.caption).foregroundStyle(.secondary).padding(12) }
                    }
                }
                .frame(width: width)
                .frame(height: model.showGallery ? max(200, geometry.size.height - (model.isProject ? 32 : 62)) : nil)
                .atlasGlass(cornerRadius: 24)
                .recordMapOverlay(.panel)
                .padding(.leading, 12).padding(.top, model.isProject ? 12 : 42)
                mapControls.recordMapOverlay(.controls)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 16).padding(.top, model.isProject ? 12 : 42)
                if model.showHeatmap && model.mappedCount > 0 {
                    HStack(spacing: 7) {
                        Text(L10n.text("Fewer"))
                        LinearGradient(colors: [Color(red: 0.61, green: 0.32, blue: 0.89), .cyan, Color(red: 1, green: 0.9, blue: 0.48), Color(red: 0.98, green: 0.54, blue: 0.76)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 66, height: 5).clipShape(Capsule())
                        Text(L10n.text("More photos"))
                    }.font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 7)
                        .atlasGlass(cornerRadius: 20)
                        .recordMapOverlay(.legend)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 16).padding(.bottom, 26)
                }
            }
            .coordinateSpace(name: "mapCanvas")
            .onPreferenceChange(MapOverlayFrames.self) { frames in
                model.mapViewportLayout = MapViewportLayout(size: geometry.size, panel: frames[.panel],
                    controls: frames[.controls], legend: frames[.legend], galleryExpanded: model.showGallery)
            }
            .onAppear { model.mapPanelInset = width + 24 }
        }.ignoresSafeArea()
    }

    private var panelHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                PlaceSearch(onResult: model.goTo)
                Button { model.showGallery.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 17)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(model.showGallery ? L10n.text("Collapse photo gallery") : L10n.text("Show photo gallery"))
                    .accessibilityLabel(L10n.text("Toggle photo gallery"))
            }
            if model.showGallery {
                HStack {
                    Image("BrandLogo", bundle: L10n.bundle)
                        .resizable().scaledToFit().frame(width: 58, height: 25)
                        .accessibilityLabel("libhm")
                    Spacer()
                    if !model.isProject {
                        Button { photosGuideOpen = true } label: {
                            Image(systemName: "questionmark.circle").font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L10n.text("Use in Apple Photos…")).accessibilityLabel(L10n.text("Use in Apple Photos…"))
                    }
                    Button { filtersOpen.toggle() } label: {
                        Image(systemName: model.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease").font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(model.filters.isActive ? Color.accentColor : .primary).help(L10n.text("Filters")).accessibilityLabel(L10n.text("Filters"))
                        .popover(isPresented: $filtersOpen) { FilterPanel(model: model).frame(width: 360) }
                    Menu {
                        Button(L10n.text("Copy map image")) { model.requestExport(save: false) }
                        Button(L10n.text("Save map as PNG…")) { model.requestExport(save: true) }
                    } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 15)).frame(width: 28, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("Export map")).disabled(model.isExporting)
                }
            }
        }.padding(16)
    }

    private var galleryContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.selection == nil ? L10n.text("In this area") : L10n.text("Selected location")).font(.headline)
                Spacer()
                Text(L10n.number(model.gallery.count)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 3).padding(.bottom, 8)
            if model.selection != nil {
                Button(L10n.text("Back to map area"), action: model.clearArea).buttonStyle(.link)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.mappedCount == 0 {
                Spacer(minLength: 0)
            } else if model.gallery.isEmpty {
                AtlasUnavailableView(icon: "photo.on.rectangle.angled", title: L10n.text("No photos here"),
                                     detail: L10n.text("Move the map or adjust your filters.")) { EmptyView() }
            } else {
                PhotoGallery(model: model)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapControls: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            VStack(spacing: 0) {
                Menu {
                    Toggle(L10n.text("Heatmap"), isOn: $model.showHeatmap)
                    Toggle(L10n.text("Satellite"), isOn: $model.satellite)
                } label: { Image(systemName: "map.fill").font(.system(size: 17)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 42, height: 40).help(L10n.text("Map appearance"))
                Divider().padding(.horizontal, 9)
                mapButton(L10n.text("Show all photos"), icon: "arrow.up.left.and.arrow.down.right", action: model.fitAll)
            }.atlasGlass(cornerRadius: 19)
            VStack(spacing: 0) {
                mapButton(L10n.text("Zoom in"), icon: "plus") { model.zoom(2) }
                Divider().padding(.horizontal, 9)
                mapButton(L10n.text("Zoom out"), icon: "minus") { model.zoom(0.5) }
            }.atlasGlass(cornerRadius: 19)
        }.frame(width: 42)
    }

    private func mapButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 42, height: 40).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func message<Actions: View>(icon: String, title: String, detail: String, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        AtlasUnavailableView(icon: icon, title: title, detail: detail, actions: actions)
    }
}

private enum MapOverlay: Hashable { case panel, controls, legend }

private struct MapOverlayFrames: PreferenceKey {
    static let defaultValue: [MapOverlay: CGRect] = [:]
    static func reduce(value: inout [MapOverlay: CGRect], nextValue: () -> [MapOverlay: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func recordMapOverlay(_ overlay: MapOverlay) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: MapOverlayFrames.self, value: [overlay: geometry.frame(in: .named("mapCanvas"))])
        })
    }
}

private struct FilterPanel: View {
    let model: AppModel
    private var dateEnabled: Binding<Bool> {
        Binding(get: { model.filters.start != nil || model.filters.end != nil }, set: { enabled in
            if enabled {
                model.filters.start = Calendar.current.startOfDay(for: model.photos.compactMap(\.date).min() ?? .now)
                model.filters.end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
            } else { model.filters.start = nil; model.filters.end = nil }
        })
    }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack { Text(L10n.text("Filter photos")).font(.headline); Spacer(); Button(L10n.text("Reset")) { model.filters = PhotoFilters() }.disabled(!model.filters.isActive) }.padding(16)
            Divider()
            Form {
            Section {
            Toggle(L10n.text("Favorites only"), isOn: $model.filters.favoritesOnly)
            Picker(L10n.text("Album"), selection: $model.filters.albumID) {
                Text(L10n.text("All albums")).tag(nil as String?)
                ForEach(model.albums) { album in Text(album.title).tag(Optional(album.id)) }
            }
            }
            Section {
            Toggle(L10n.text("Date range"), isOn: dateEnabled)
            if dateEnabled.wrappedValue {
                DatePicker(L10n.text("From"), selection: Binding(get: { model.filters.start ?? .now }, set: { value in
                    let day = Calendar.current.startOfDay(for: value)
                    model.filters.start = day
                    if let end = model.filters.end, end <= day { model.filters.end = Calendar.current.date(byAdding: .day, value: 1, to: day) }
                }), displayedComponents: .date)
                DatePicker(L10n.text("Through"), selection: Binding(get: { (model.filters.end ?? .now).addingTimeInterval(-1) }, set: { value in
                    let day = Calendar.current.startOfDay(for: value)
                    model.filters.end = Calendar.current.date(byAdding: .day, value: 1, to: day)
                    if let start = model.filters.start, start > day { model.filters.start = day }
                }), displayedComponents: .date)
            }
            }
            }.formStyle(.grouped).scrollDisabled(true).frame(height: dateEnabled.wrappedValue ? 280 : 175)
        }
    }
}
