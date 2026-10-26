import AppKit
import SwiftUI

/// A real AppKit responder is necessary in Photos' remote view hierarchy.
struct ViewerKeyboardContainer<Content: View>: NSViewRepresentable {
    let focusToken: String
    let handle: (ViewerKeyCommand) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ViewerKeyView<Content> {
        ViewerKeyView(rootView: content(), handle: handle)
    }
    func updateNSView(_ view: ViewerKeyView<Content>, context: Context) {
        view.host.rootView = content()
        view.handle = handle
        if view.focusToken != focusToken {
            view.focusToken = focusToken
            view.requestKeyboardFocus()
        }
    }
    static func dismantleNSView(_ view: ViewerKeyView<Content>, coordinator: ()) {
        view.handle = nil
    }
}

enum ViewerKeyCommand: Equatable {
    case previous, next, close, zoomIn, zoomOut, fit, information

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123: self = .previous
        case 124: self = .next
        case 53, 49: self = .close
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "+", "=": self = .zoomIn
            case "-": self = .zoomOut
            case "0": self = .fit
            case "i", "ш": self = .information
            default: return nil
            }
        }
    }
}

@MainActor
final class ViewerKeyView<Content: View>: NSView {
    let host: NSHostingView<Content>
    var handle: ((ViewerKeyCommand) -> Void)?
    var focusToken = ""

    init(rootView: Content, handle: @escaping (ViewerKeyCommand) -> Void) {
        self.host = NSHostingView(rootView: rootView)
        self.handle = handle
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestKeyboardFocus()
    }
    func requestKeyboardFocus() {
        // Defer until SwiftUI has installed its new subtree in the remote window.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, handle != nil else { return }
            window.makeFirstResponder(self)
        }
    }
    override func keyDown(with event: NSEvent) {
        if let command = ViewerKeyCommand(event: event), let handle { handle(command) }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let focused sliders and editable fields keep their own key bindings.
        if window?.firstResponder is NSSlider || window?.firstResponder is NSTextView {
            return super.performKeyEquivalent(with: event)
        }
        if let command = ViewerKeyCommand(event: event), let handle {
            handle(command); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
