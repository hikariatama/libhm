import AppKit
import SwiftUI
import XCTest

final class ViewerKeyboardTests: XCTestCase {
    @MainActor
    func testViewerResponderRoutesNavigationCloseAndZoom() throws {
        var commands: [ViewerKeyCommand] = []
        let view = ViewerKeyView(rootView: EmptyView()) { commands.append($0) }
        for (code, text) in [(UInt16(123), ""), (124, ""), (49, " "), (53, ""), (24, "+"), (27, "-"), (29, "0"), (34, "ш")] {
            view.keyDown(with: try event(code: code, characters: text))
        }
        XCTAssertEqual(commands, [.previous, .next, .close, .close, .zoomIn, .zoomOut, .fit, .information])
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    @MainActor
    func testSystemModifierShortcutsAreNotConsumed() throws {
        for modifier in [NSEvent.ModifierFlags.command, .control, .option] {
            XCTAssertNil(ViewerKeyCommand(event: try event(code: 124, characters: "", modifiers: modifier)))
            XCTAssertNil(ViewerKeyCommand(event: try event(code: 49, characters: " ", modifiers: modifier)))
        }
        XCTAssertNil(ViewerKeyCommand(event: try event(code: 48, characters: "\t")))
    }

    @MainActor
    func testOwnedWindowAcceptsViewerAndRoutesKeysAfterControlFocus() throws {
        _ = NSApplication.shared
        var commands: [ViewerKeyCommand] = []
        let view = ViewerKeyView(rootView: EmptyView()) { commands.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(view.performKeyEquivalent(with: try event(code: 124, characters: "")))
        let slider = NSSlider(value: 1, minValue: 1, maxValue: 8, target: nil, action: nil)
        view.addSubview(slider)
        XCTAssertTrue(window.makeFirstResponder(slider))
        XCTAssertFalse(view.performKeyEquivalent(with: try event(code: 124, characters: "")))
        XCTAssertTrue(window.makeFirstResponder(view))
        view.keyDown(with: try event(code: 53, characters: ""))
        XCTAssertEqual(commands, [.next, .close])
        window.close()
    }

    private func event(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
