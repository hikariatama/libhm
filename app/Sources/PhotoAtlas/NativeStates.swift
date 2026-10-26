import SwiftUI

struct AtlasLoadingView: View {
    let title: String
    var progress: Double?
    var body: some View {
        VStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress).frame(width: 160)
                Text(L10n.format("Downloading from iCloud · %@", L10n.percent(progress)))
            } else {
                ProgressView().controlSize(.small)
                Text(title)
            }
        }.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
    }
}

struct AtlasUnavailableView<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail).frame(maxWidth: 380)
        } actions: {
            actions()
        }.buttonStyle(.bordered).controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
