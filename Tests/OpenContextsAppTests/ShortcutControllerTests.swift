import AppKit
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

@MainActor
final class ShortcutControllerTests: XCTestCase {
    private let custom = KeyboardShortcut(keyCode: 16, modifiers: [.maskControl, .maskAlternate], keyLabel: "Y")
    private let sameKey = KeyboardShortcut(keyCode: 16, modifiers: .maskCommand, keyLabel: "Y")

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testShortcutStateLifecycle() {
        var state = ShortcutState()
        XCTAssertEqual(KeyboardShortcut.allWindows.display, "⌘Tab")
        XCTAssertEqual(KeyboardShortcut.currentApp.display, "⌘`")
        XCTAssertNil(state.begin(currentAppOnly: false, reverse: false, allowed: false))
        XCTAssertEqual(state.begin(currentAppOnly: false, reverse: false, allowed: true),
                       .begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(state.step(1), .step(1))
        XCTAssertEqual(state.finish(commit: false), .cancel)
        XCTAssertEqual(state.begin(currentAppOnly: true, reverse: true, allowed: true),
                       .begin(currentAppOnly: true, reverse: true))
        XCTAssertEqual(state.finish(commit: true), .commit)
        XCTAssertNil(state.finish(commit: true))
    }

    func testDefaultShortcutsDriveSwitching() {
        let controller = ShortcutController()
        XCTAssertNil(controller.keyAction(keyCode: 48, flags: []))
        XCTAssertNil(controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskControl]))
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]),
                       .begin(currentAppOnly: false, reverse: true))
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]), .step(-1))
        XCTAssertEqual(controller.keyAction(keyCode: 50, flags: .maskCommand), .step(1))
        XCTAssertNil(controller.modifierAction(flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(controller.modifierAction(flags: .maskShift), .commit)
        XCTAssertEqual(controller.keyAction(keyCode: 50, flags: .maskCommand), .begin(currentAppOnly: true, reverse: false))
        XCTAssertEqual(controller.keyAction(keyCode: 53, flags: .maskCommand), .cancel)
    }

    func testShortcutValidation() {
        XCTAssertTrue(custom.isValid)
        XCTAssertEqual(custom.display, "⌃⌥Y")
        XCTAssertFalse(custom.conflicts(with: sameKey))
        XCTAssertFalse(KeyboardShortcut(keyCode: 16, modifiers: [], keyLabel: "Y").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 16, modifiers: [.maskCommand, .maskShift], keyLabel: "Y").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 53, modifiers: .maskCommand, keyLabel: "Esc").isValid)
    }

    func testCustomShortcutsReplaceDefaults() {
        let controller = ShortcutController()
        controller.configure(allWindows: custom, currentApp: sameKey)
        XCTAssertNil(controller.keyAction(keyCode: 48, flags: .maskCommand))
        XCTAssertNil(controller.keyAction(keyCode: 50, flags: .maskCommand))
        XCTAssertNil(controller.keyAction(keyCode: 16, flags: .maskControl))
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: [.maskControl, .maskAlternate, .maskShift]),
                       .begin(currentAppOnly: false, reverse: true))
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: custom.modifiers), .step(1))
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: [.maskControl, .maskAlternate, .maskShift]), .step(-1))
        XCTAssertEqual(controller.keyAction(keyCode: 126, flags: custom.modifiers), .step(-1))
        XCTAssertEqual(controller.keyAction(keyCode: 125, flags: custom.modifiers), .step(1))
        XCTAssertNil(controller.keyAction(keyCode: 0, flags: custom.modifiers))
        XCTAssertNil(controller.modifierAction(flags: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertEqual(controller.modifierAction(flags: .maskControl), .commit)
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: .maskCommand), .begin(currentAppOnly: true, reverse: false))
        XCTAssertEqual(controller.modifierAction(flags: []), .commit)

        controller.canBegin = { _ in false }
        XCTAssertNil(controller.keyAction(keyCode: 16, flags: custom.modifiers))
        controller.canBegin = nil
        XCTAssertNotNil(controller.keyAction(keyCode: 16, flags: custom.modifiers))

        var cancelled = false
        controller.onAction = { cancelled = $0 == .cancel }
        controller.configure(allWindows: .allWindows, currentApp: .currentApp)
        XCTAssertTrue(cancelled)
        XCTAssertNil(controller.modifierAction(flags: []))
        controller.configure(allWindows: .allWindows, currentApp: .allWindows)
        XCTAssertEqual(controller.currentAppShortcut, .currentApp)
    }

    func testSidebarShortcut() {
        let controller = ShortcutController()
        XCTAssertEqual(KeyboardShortcut.sidebar.display, "⌃⌘B")
        XCTAssertEqual(controller.keyAction(keyCode: 11, flags: [.maskControl, .maskCommand]), .toggleSidebar)
        XCTAssertNil(controller.modifierAction(flags: []))
        XCTAssertNil(controller.keyAction(keyCode: 11, flags: [.maskControl, .maskCommand, .maskShift]))
        XCTAssertNil(controller.keyAction(keyCode: 11, flags: .maskCommand))
        XCTAssertNil(controller.keyAction(keyCode: 53, flags: []))

        XCTAssertNotNil(controller.keyAction(keyCode: 48, flags: .maskCommand))
        XCTAssertEqual(controller.keyAction(keyCode: 53, flags: .maskCommand), .cancel)
        XCTAssertNotNil(controller.keyAction(keyCode: 48, flags: .maskCommand))
        XCTAssertEqual(controller.keyAction(keyCode: 11, flags: [.maskControl, .maskCommand]), .toggleSidebar)
        XCTAssertNil(controller.modifierAction(flags: []))

        controller.configure(allWindows: .allWindows, currentApp: .currentApp, sidebar: custom)
        XCTAssertEqual(controller.sidebarShortcut, custom)
        XCTAssertNil(controller.keyAction(keyCode: 11, flags: [.maskControl, .maskCommand]))
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: custom.modifiers), .toggleSidebar)
        controller.configure(allWindows: .allWindows, currentApp: .currentApp, sidebar: .allWindows)
        XCTAssertEqual(controller.sidebarShortcut, custom)
        controller.configure(allWindows: .allWindows, currentApp: .currentApp, sidebar: nil)
        XCTAssertNil(controller.sidebarShortcut)
        XCTAssertNil(controller.keyAction(keyCode: 16, flags: custom.modifiers))
    }

    func testRecordingShortcuts() throws {
        let controller = ShortcutController()
        let event = try keyEvent("y", keyCode: 16, modifiers: [.control, .option])
        let recorded = try XCTUnwrap(KeyboardShortcut(event: event))
        XCTAssertTrue(recorded.matches(keyCode: 16, flags: custom.modifiers))
        XCTAssertEqual(recorded.keyLabel, "Y")
        XCTAssertEqual(ShortcutController.searchCharacters(event), "y")

        var acceptRecording = false
        var saved: KeyboardShortcut?
        controller.beginRecording(target: .sidebar) { shortcut in
            guard acceptRecording else { return false }
            saved = shortcut
            return true
        }
        defer { controller.cancelRecording() }
        controller.record(event)
        XCTAssertEqual(controller.recordingTarget, .sidebar)
        XCTAssertEqual(controller.recordingErrorKey, "Shortcuts must be different.")
        XCTAssertNil(saved)
        acceptRecording = true
        controller.record(event)
        XCTAssertEqual(saved, recorded)
        XCTAssertNil(controller.recordingTarget)
        XCTAssertNil(controller.recordingMonitor)
        XCTAssertNil(controller.recordingErrorKey)

        controller.beginRecording(target: .currentApp) { _ in false }
        controller.record(try keyEvent("y", keyCode: 16))
        XCTAssertEqual(controller.recordingTarget, .currentApp)
        XCTAssertNotNil(controller.recordingErrorKey)
        controller.record(try keyEvent("\u{1b}", keyCode: 53))
        XCTAssertNil(controller.recordingTarget)
        XCTAssertNil(controller.recordingMonitor)
        XCTAssertNil(controller.recordingErrorKey)
    }

    func testSearchWhileSwitching() {
        let controller = ShortcutController()
        XCTAssertNil(controller.keyAction(keyCode: 13, flags: .maskCommand, characters: "w"))
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: .maskCommand), .begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(controller.keyAction(keyCode: 13, flags: .maskCommand, characters: "w"), .search("w"))
        XCTAssertEqual(controller.keyAction(keyCode: 12, flags: .maskCommand, characters: "q"), .search("wq"))
        XCTAssertEqual(controller.keyAction(keyCode: 8, flags: .maskCommand, characters: "C"), .search("wqC"))
        XCTAssertEqual(controller.keyAction(keyCode: 49, flags: .maskCommand, characters: " "), .search("wqC "))
        XCTAssertEqual(controller.keyAction(keyCode: 51, flags: .maskCommand), .search("wqC"))
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]), .step(-1))
        XCTAssertEqual(controller.keyAction(keyCode: 0, flags: .maskCommand, characters: "中"), .search("wqC中"))
        XCTAssertEqual(controller.keyAction(keyCode: 51, flags: .maskCommand), .search("wqC"))
        XCTAssertNil(controller.keyAction(keyCode: 122, flags: .maskCommand, characters: "\u{f704}"))
        XCTAssertEqual(controller.modifierAction(flags: []), .commit)
        XCTAssertTrue(controller.state.searchQuery.isEmpty)
        XCTAssertEqual(controller.keyAction(keyCode: 48, flags: .maskCommand), .begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(controller.keyAction(keyCode: 51, flags: .maskCommand), .search(""))
        XCTAssertEqual(controller.keyAction(keyCode: 0, flags: .maskCommand, characters: "a"), .search("a"))
        XCTAssertEqual(controller.keyAction(keyCode: 53, flags: .maskCommand), .cancel)
        XCTAssertTrue(controller.state.searchQuery.isEmpty)

        controller.configure(allWindows: custom, currentApp: sameKey)
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: custom.modifiers), .begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(controller.keyAction(keyCode: 0, flags: custom.modifiers, characters: "a"), .search("a"))
        XCTAssertEqual(controller.keyAction(keyCode: 16, flags: custom.modifiers, characters: "y"), .search("ay"))
        XCTAssertEqual(controller.modifierAction(flags: .maskControl), .commit)
        XCTAssertTrue(controller.state.searchQuery.isEmpty)
    }

    func testReleasedControllerTearsDownItsEventTap() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "creating an event tap needs Accessibility trust")
        var controller: ShortcutController? = ShortcutController()
        weak var released = controller
        XCTAssertTrue(try XCTUnwrap(controller).start())
        let tap = try XCTUnwrap(controller?.eventTap)
        XCTAssertTrue(CFMachPortIsValid(tap))
        controller = nil
        XCTAssertNil(released, "the event tap or its observers kept the controller alive")
        XCTAssertFalse(CFMachPortIsValid(tap), "the event tap outlived its controller")

        let stopped = ShortcutController()
        XCTAssertTrue(stopped.start())
        let stoppedTap = try XCTUnwrap(stopped.eventTap)
        stopped.stop()
        XCTAssertNil(stopped.eventTap)
        XCTAssertFalse(CFMachPortIsValid(stoppedTap))
        XCTAssertTrue(stopped.start(), "a stopped controller could not start again")
        stopped.stop()
    }

    func testSearchAcceptsTextFromAnyLayoutButNotControlOrFunctionKeys() {
        for text in ["ж", "é", "日本", "ש", " ", "a b", "😀", "ß"] {
            var state = ShortcutState()
            _ = state.begin(currentAppOnly: false, reverse: false, allowed: true)
            XCTAssertEqual(state.appendToSearch(text), .search(text), text)
        }
        for text in ["\t", "\r", "\u{7F}", "\u{1B}", "\u{F700}", "\u{F728}", "a\u{F701}", "\u{200B}", ""] {
            var state = ShortcutState()
            _ = state.begin(currentAppOnly: false, reverse: false, allowed: true)
            XCTAssertNil(state.appendToSearch(text), text.unicodeScalars.map { String($0.value, radix: 16) }.joined())
        }
        var random = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            guard let scalar = Unicode.Scalar(UInt32.random(in: 0...0x10FFFF, using: &random)) else { continue }
            var state = ShortcutState()
            _ = state.begin(currentAppOnly: false, reverse: false, allowed: true)
            let rejected: Set<Unicode.GeneralCategory> = [.control, .format, .privateUse, .surrogate, .unassigned,
                                                          .lineSeparator, .paragraphSeparator]
            XCTAssertEqual(state.appendToSearch(String(scalar)) != nil,
                           !rejected.contains(scalar.properties.generalCategory), String(scalar.value, radix: 16))
        }
        var idle = ShortcutState()
        XCTAssertNil(idle.appendToSearch("ж"), "search text was accepted while not switching")
    }

    func testRecordedShortcutLabelsAndRejectedKeys() throws {
        let named: [(UInt16, String)] = [(48, "Tab"), (49, "Space"), (36, "↩"), (51, "⌫"), (117, "⌦"),
                                          (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
                                          (122, "F1"), (120, "F2"), (111, "F12"), (90, "F20")]
        for (keyCode, label) in named {
            let shortcut = try XCTUnwrap(KeyboardShortcut(event: try keyEvent("x", keyCode: keyCode, modifiers: .command)),
                                         label)
            XCTAssertEqual(shortcut.keyLabel, label)
            XCTAssertEqual(shortcut.display, "⌘" + label)
        }
        let letter = try XCTUnwrap(KeyboardShortcut(event: try keyEvent("é", keyCode: 14, modifiers: [.control, .option])))
        XCTAssertEqual(letter.keyLabel, "É")
        XCTAssertEqual(letter.display, "⌃⌥É")
        XCTAssertEqual(letter.modifiers, [.maskControl, .maskAlternate])

        XCTAssertNil(KeyboardShortcut(event: try keyEvent("a", keyCode: 0)), "a shortcut needs a modifier")
        XCTAssertNil(KeyboardShortcut(event: try keyEvent("A", keyCode: 0, modifiers: [.command, .shift])),
                     "Shift is reserved for switching backward")
        XCTAssertNil(KeyboardShortcut(event: try keyEvent("\u{1B}", keyCode: 53, modifiers: .command)), "Escape cancels")
        for modifierKey in UInt16(54)...63 {
            XCTAssertNil(KeyboardShortcut(event: try keyEvent("", keyCode: modifierKey, modifiers: .command)))
        }
        XCTAssertNil(KeyboardShortcut(event: try keyEvent("", keyCode: 0, modifiers: .command)), "no label")
        XCTAssertNil(KeyboardShortcut(event: try keyEvent(String(repeating: "x", count: 21), keyCode: 0,
                                                          modifiers: .command)), "label too long")

        for keyCode in UInt16(0)..<128 {
            guard let shortcut = KeyboardShortcut(event: try keyEvent("k", keyCode: keyCode, modifiers: .option)) else {
                XCTAssertTrue(keyCode == 53 || (54...63).contains(keyCode), "key \(keyCode) was rejected")
                continue
            }
            XCTAssertTrue(shortcut.isValid)
            XCTAssertTrue(shortcut.matches(keyCode: keyCode, flags: [.maskAlternate, .maskShift]),
                          "Shift must not stop the reverse direction from matching")
            XCTAssertFalse(shortcut.matches(keyCode: keyCode, flags: [.maskAlternate, .maskCommand]))
        }
    }

    private func trustedController() -> ShortcutController {
        let controller = ShortcutController()
        controller.isTrusted = { true }
        controller.onAction = { _ in }
        return controller
    }

    private func keyDown(_ keyCode: CGKeyCode, flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = flags
        return event
    }

    func testEventTapSwallowsExactlyWhatTheControllerConsumes() throws {
        let controller = trustedController()
        let commandTab = try keyDown(48, flags: .maskCommand)
        XCTAssertNil(ShortcutTapContext(controller).respond(type: .keyDown, event: commandTab),
                     "⌘Tab reached the system switcher too")
        XCTAssertTrue(controller.state.isSwitching)
        let other = trustedController()
        let plain = try keyDown(0, flags: [])
        XCTAssertTrue(ShortcutTapContext(other).respond(type: .keyDown, event: plain)?.takeUnretainedValue() === plain)

        var random = SystemRandomNumberGenerator()
        let modifiers: [CGEventFlags] = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<2_000 {
            let keyCode = CGKeyCode.random(in: 0..<128, using: &random)
            let flags = modifiers.filter { _ in Bool.random(using: &random) }
                .reduce(into: CGEventFlags()) { $0.insert($1) }
            let viaTap = trustedController()
            let direct = trustedController()
            let context = ShortcutTapContext(viaTap)
            for type in [CGEventType.flagsChanged, .keyDown] {
                let event = try keyDown(keyCode, flags: flags)
                let tapResult = context.respond(type: type, event: event)
                let directResult = direct.handle(type: type, event: event)
                let message = "key \(keyCode), flags \(flags.rawValue), type \(type.rawValue)"
                XCTAssertEqual(tapResult == nil, directResult == nil, message)
                if let tapResult { XCTAssertTrue(tapResult.takeUnretainedValue() === event, message) }
            }
            XCTAssertEqual(viaTap.state.isSwitching, direct.state.isSwitching)
        }
    }

    func testEventTapPassesEventsThroughOnceItsControllerIsReleased() throws {
        var controller: ShortcutController? = trustedController()
        let context = ShortcutTapContext(try XCTUnwrap(controller))
        controller = nil
        XCTAssertNil(context.controller)
        let commandTab = try keyDown(48, flags: .maskCommand)
        XCTAssertTrue(context.respond(type: .keyDown, event: commandTab)?.takeUnretainedValue() === commandTab)
    }
}
