@preconcurrency import ApplicationServices
import AppKit
import Combine

struct KeyboardShortcut: Codable, Equatable {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    static let allWindows = KeyboardShortcut(keyCode: 48, modifiers: .maskCommand, keyLabel: "Tab")
    static let currentApp = KeyboardShortcut(keyCode: 50, modifiers: .maskCommand, keyLabel: "`")
    static let sidebar = KeyboardShortcut(keyCode: 11, modifiers: [.maskControl, .maskCommand], keyLabel: "B")

    let keyCode: UInt16
    let modifierRawValue: UInt64
    let keyLabel: String

    init(keyCode: UInt16, modifiers: CGEventFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierRawValue = modifiers.rawValue
        self.keyLabel = keyLabel
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }
    var isValid: Bool {
        keyCode < 128 && keyCode != 53 && !(54...63).contains(keyCode)
            && !modifiers.isEmpty && modifiers.subtracting(Self.modifierMask).isEmpty
            && !keyLabel.isEmpty && keyLabel.count <= 20
    }
    var display: String {
        (modifiers.contains(.maskControl) ? "⌃" : "")
            + (modifiers.contains(.maskAlternate) ? "⌥" : "")
            + (modifiers.contains(.maskCommand) ? "⌘" : "") + keyLabel
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && flags.intersection(Self.modifierMask) == modifiers
    }

    func conflicts(with other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && modifierRawValue == other.modifierRawValue
    }

    init?(event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        guard !flags.contains(.maskShift) else { return nil }
        let names: [UInt16: String] = [
            36: "↩", 48: "Tab", 49: "Space", 51: "⌫", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
        ]
        let functionKeys: [UInt16: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
            109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
        ]
        let label = names[event.keyCode] ?? functionKeys[event.keyCode].map { "F\($0)" }
            ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        self.init(keyCode: event.keyCode, modifiers: flags.intersection(Self.modifierMask), keyLabel: label)
        guard isValid else { return nil }
    }
}

enum ShortcutTarget: String, CaseIterable {
    case allWindows, currentApp, sidebar

    var title: String {
        switch self {
        case .allWindows: "All windows"
        case .currentApp: "Current app windows"
        case .sidebar: "Show or hide sidebar"
        }
    }
}

enum SwitcherAction: Equatable {
    case toggleSidebar
    case begin(currentAppOnly: Bool, reverse: Bool)
    case step(Int)
    case search(String)
    case commit
    case cancel
}

struct ShortcutState {
    private(set) var isSwitching = false
    private(set) var heldModifiers: CGEventFlags = []
    private(set) var searchQuery = ""

    mutating func begin(currentAppOnly: Bool, reverse: Bool, allowed: Bool,
                        modifiers: CGEventFlags = .maskCommand) -> SwitcherAction? {
        guard !isSwitching, allowed else { return nil }
        isSwitching = true
        heldModifiers = modifiers
        searchQuery = ""
        return .begin(currentAppOnly: currentAppOnly, reverse: reverse)
    }

    mutating func step(_ amount: Int) -> SwitcherAction? {
        isSwitching ? .step(amount) : nil
    }

    mutating func appendToSearch(_ characters: String) -> SwitcherAction? {
        guard isSwitching, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy(Self.isSearchable) else { return nil }
        searchQuery += characters
        return .search(searchQuery)
    }

    /// Text from any keyboard layout; rejects control characters and the private-use code points AppKit
    /// reports for function and arrow keys.
    static func isSearchable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }

    mutating func deleteFromSearch() -> SwitcherAction? {
        guard isSwitching else { return nil }
        if !searchQuery.isEmpty { searchQuery.removeLast() }
        return .search(searchQuery)
    }

    mutating func finish(commit: Bool) -> SwitcherAction? {
        guard isSwitching else { return nil }
        isSwitching = false
        heldModifiers = []
        searchQuery = ""
        return commit ? .commit : .cancel
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var recordingTarget: ShortcutTarget?
    @Published private(set) var recordingErrorKey: String?
    var onAction: ((SwitcherAction) -> Void)?
    var canBegin: ((Bool) -> Bool)?
    private(set) var allWindowsShortcut = KeyboardShortcut.allWindows
    private(set) var currentAppShortcut = KeyboardShortcut.currentApp
    private(set) var sidebarShortcut: KeyboardShortcut? = .sidebar

    private(set) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapContext: Unmanaged<ShortcutTapContext>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private(set) var state = ShortcutState()
    private(set) var recordingMonitor: Any?
    private var saveRecording: ((KeyboardShortcut) -> Bool)?
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapContext?.release()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func configure(allWindows: KeyboardShortcut, currentApp: KeyboardShortcut,
                   sidebar: KeyboardShortcut? = .sidebar) {
        guard allWindows.isValid, currentApp.isValid, !allWindows.conflicts(with: currentApp),
              sidebar.map({ $0.isValid && !$0.conflicts(with: allWindows) && !$0.conflicts(with: currentApp) }) ?? true,
              allWindows != allWindowsShortcut || currentApp != currentAppShortcut
                || sidebar != sidebarShortcut else { return }
        if let action = state.finish(commit: false) { onAction?(action) }
        allWindowsShortcut = allWindows
        currentAppShortcut = currentApp
        sidebarShortcut = sidebar
    }

    func beginRecording(target: ShortcutTarget, onSave: @escaping (KeyboardShortcut) -> Bool) {
        cancelRecording()
        if let action = state.finish(commit: false) { onAction?(action) }
        recordingTarget = target
        saveRecording = onSave
        // Also records in Settings before Accessibility permission is granted.
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let captured = MainActor.assumeIsolated {
                guard let self, self.recordingTarget != nil else { return false }
                self.record(event)
                return true
            }
            return captured ? nil : event
        }
    }

    func cancelRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        saveRecording = nil
        recordingTarget = nil
        recordingErrorKey = nil
    }

    func record(_ event: NSEvent) {
        guard recordingTarget != nil, !event.isARepeat else { return }
        if event.keyCode == 53 {
            cancelRecording()
        } else if let shortcut = KeyboardShortcut(event: event) {
            if saveRecording?(shortcut) == true {
                cancelRecording()
            } else {
                recordingErrorKey = "Shortcuts must be different."
            }
        } else {
            recordingErrorKey = "Use Command, Option or Control with a key; Shift is reserved for reverse switching."
        }
    }

    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let eventTap {
            // The tap survives transient trust loss or session switches; re-enable it instead of no-op.
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isRunning = true
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // The tap holds a retained context with a weak reference, so it never points at a freed controller.
        let context = Unmanaged.passRetained(ShortcutTapContext(self))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutEventCallback,
            userInfo: context.toOpaque()
        ) else {
            context.release()
            return false
        }
        tapContext = context

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        observeSessionChanges()
        return true
    }

    func stop() {
        cancelRecording()
        if let action = state.finish(commit: false) { onAction?(action) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tapContext?.release()
        tapContext = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    func resetState() {
        _ = state.finish(commit: false)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            if isTrusted(), let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isTrusted() else {
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            isRunning = false
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if type == .flagsChanged {
            if let action = modifierAction(flags: flags) { emit(action, deferred: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if recordingTarget != nil {
            // Defer AppKit/UI work until after the event tap returns, and swallow even ⌘Tab.
            if let keyEvent = NSEvent(cgEvent: event) {
                DispatchQueue.main.async { [weak self] in self?.record(keyEvent) }
            }
            return nil
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard onAction != nil else { return Unmanaged.passUnretained(event) }
        let characters = state.isSwitching ? NSEvent(cgEvent: event).flatMap(Self.searchCharacters) : nil
        guard let action = keyAction(keyCode: keyCode, flags: flags, characters: characters) else {
            // No key commands may reach the frontmost app while the switcher owns input.
            return state.isSwitching ? nil : Unmanaged.passUnretained(event)
        }
        if action != .toggleSidebar || event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            emit(action, deferred: true)
        }
        return nil
    }

    func modifierAction(flags: CGEventFlags) -> SwitcherAction? {
        guard state.isSwitching, !flags.contains(state.heldModifiers) else { return nil }
        return state.finish(commit: true)
    }

    static func searchCharacters(_ event: NSEvent) -> String? {
        event.charactersIgnoringModifiers
    }

    func keyAction(keyCode: UInt16, flags: CGEventFlags, characters: String? = nil) -> SwitcherAction? {
        if !flags.contains(.maskShift), sidebarShortcut?.matches(keyCode: keyCode, flags: flags) == true {
            _ = state.finish(commit: false)
            return .toggleSidebar
        }
        if state.isSwitching {
            if state.searchQuery.isEmpty,
               allWindowsShortcut.matches(keyCode: keyCode, flags: flags)
                || currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
                return state.step(flags.contains(.maskShift) ? -1 : 1)
            }
            switch keyCode {
            case 48, 50:
                return state.step(flags.contains(.maskShift) ? -1 : 1)
            case 126:
                return state.step(-1)
            case 125:
                return state.step(1)
            case 51:
                return state.deleteFromSearch()
            case 53:
                return state.finish(commit: false)
            default:
                return characters.flatMap { state.appendToSearch($0) }
            }
        }

        let currentAppOnly: Bool
        let shortcut: KeyboardShortcut
        if allWindowsShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = false
            shortcut = allWindowsShortcut
        } else if currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = true
            shortcut = currentAppShortcut
        } else {
            return nil
        }

        return state.begin(
            currentAppOnly: currentAppOnly,
            reverse: flags.contains(.maskShift),
            allowed: canBegin?(currentAppOnly) ?? true,
            modifiers: shortcut.modifiers
        )
    }

    private func emit(_ action: SwitcherAction, deferred: Bool) {
        guard deferred else {
            onAction?(action)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func observeSessionChanges() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancelRecording()
                    if let action = self.state.finish(commit: false) { self.onAction?(action) }
                    if let eventTap = self.eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
                    self.isRunning = false
                }
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard AXIsProcessTrusted(), let eventTap = self?.eventTap else { return }
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    self?.isRunning = true
                }
            }
        ]
    }
}

final class ShortcutTapContext {
    weak var controller: ShortcutController?

    init(_ controller: ShortcutController) {
        self.controller = controller
    }

    /// A nil result swallows the event, so it must not be coalesced with the released-controller case.
    @MainActor
    func respond(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let controller else { return Unmanaged.passUnretained(event) }
        return controller.handle(type: type, event: event)
    }
}

private let shortcutEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<ShortcutTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { context.respond(type: type, event: event) }
}
