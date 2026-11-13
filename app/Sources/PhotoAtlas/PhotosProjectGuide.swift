import AppKit
import SwiftUI

private struct PhotosProjectGuideActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var showPhotosProjectGuide: (() -> Void)? {
        get { self[PhotosProjectGuideActionKey.self] }
        set { self[PhotosProjectGuideActionKey.self] = newValue }
    }
}

struct PhotosProjectGuide: View {
    let isProject: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var openFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Use in Apple Photos")).font(.title2.bold())
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(1, title: "Set up libhm") {
                        Text(L10n.text("Copy libhm to Applications, open it once, and allow access to your photo library."))
                    }
                    step(2, title: "Create a project in Photos") {
                        Text(L10n.text("Open Photos, go to Library, and select any photo. Then choose:"))
                        Text(L10n.text("File → Create → Other → libhm"))
                            .fontWeight(.medium).foregroundStyle(.primary).textSelection(.enabled)
                        Text(L10n.text("If a project picker appears, choose Heatmap. The map uses your entire System Photo Library, regardless of the photo you selected. New photos appear automatically."))
                    }
                    step(3, title: "Pin the project") {
                        if #available(macOS 26.0, *) {
                            Text(L10n.text("Find your map under Projects in the Photos sidebar. Control-click it (or right-click), then choose Pin. Open it from Pinned whenever you want to return to the map."))
                        } else {
                            Text(L10n.text("Find your map under Projects in the Photos sidebar. Open it there whenever you want to return to the map. Pinning is available in macOS 26 and later."))
                        }
                    }
                    DisclosureGroup(L10n.text("libhm is missing from the menu")) {
                        Text(L10n.text("In Photos, choose File → Create → Manage. Open Photos Projects and enable libhm. If it still does not appear, quit and reopen Photos."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if !isProject {
                    Button(L10n.text("Open Photos"), action: openPhotos)
                }
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 540, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, L10n.locale)
        .onExitCommand { dismiss() }
        .alert(L10n.text("Couldn’t open Photos"), isPresented: $openFailed) {
            Button(L10n.text("OK"), role: .cancel) { }
        } message: {
            Text(L10n.text("Open Photos from Applications to continue."))
        }
    }

    private func step<Detail: View>(_ number: Int, title: String, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.number(number)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text(title)).font(.headline).accessibilityAddTraits(.isHeader)
                detail().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openPhotos() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos"),
              NSWorkspace.shared.open(url) else {
            openFailed = true
            return
        }
    }
}

#if !PHOTO_PROJECT_EXTENSION
struct PhotosProjectGuideCommands: Commands {
    @FocusedValue(\.showPhotosProjectGuide) private var showGuide

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L10n.text("Use in Apple Photos…")) { showGuide?() }
                .disabled(showGuide == nil)
        }
    }
}
#endif
