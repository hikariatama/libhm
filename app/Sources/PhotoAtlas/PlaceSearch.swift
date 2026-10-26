@preconcurrency import MapKit
import SwiftUI

@MainActor
@Observable
final class PlaceSearchModel: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    var text = "" { didSet { if text != resolvedText { completer.queryFragment = text }; if text.isEmpty { results = [] } } }
    var resolvedText: String?
    var results: [MKLocalSearchCompletion] = []
    var error: String?
    var searching = false
    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?
    private var generation = 0

    override init() { super.init(); completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest] }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = Array(completer.results.prefix(6)); error = nil }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) { self.error = L10n.text("Search is unavailable. Try again."); results = [] }

    func choose(_ completion: MKLocalSearchCompletion?, onResult: @escaping (MKMapItem) -> Void) {
        generation += 1; let token = generation
        search?.cancel(); searching = true; error = nil
        let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
        if completion == nil { request.naturalLanguageQuery = text }
        let task = MKLocalSearch(request: request); search = task
        Task {
            do {
                let response = try await task.start()
                guard generation == token else { return }
                searching = false
                if let item = response.mapItems.first {
                    results = []; if let completion { resolvedText = completion.title; text = completion.title }; results = []
                    onResult(item)
                } else { error = L10n.text("No places found.") }
            } catch {
                guard generation == token else { return }
                searching = false; self.error = L10n.text("Couldn’t find that place. Check your connection and retry.")
            }
        }
    }
}

struct PlaceSearch: View {
    let onResult: (MKMapItem) -> Void
    @State private var search = PlaceSearchModel()
    @State private var showing = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.text("Search places"), text: $search.text)
                .textFieldStyle(.plain)
                .onSubmit { search.choose(nil, onResult: onResult); showing = false }
                .onChange(of: search.text) { _, text in showing = !text.isEmpty && text != search.resolvedText }
                .onChange(of: search.error) { _, error in if error != nil { showing = true } }
            if search.searching { ProgressView().controlSize(.small) }
            if !search.text.isEmpty {
                Button { search.text = ""; showing = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.text("Clear search"))
            }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if let error = search.error { Text(error).foregroundStyle(.secondary).padding() }
                else if search.results.isEmpty { Text(L10n.text("Searching places…")).foregroundStyle(.secondary).padding() }
                ForEach(Array(search.results.enumerated()), id: \.offset) { _, result in
                    Button {
                        search.choose(result, onResult: onResult); showing = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                    }.buttonStyle(.plain)
                }
            }.frame(width: 330)
        }
    }
}
