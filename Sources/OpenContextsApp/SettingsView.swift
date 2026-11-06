import AppKit
import OpenContextsCore
import SwiftUI

enum SidebarVisibilityMode: String, CaseIterable, Identifiable {
    case always
    case hover
    case hidden

    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .always: L10n.text("Always visible", language: language)
        case .hover: L10n.text("Show on hover", language: language)
        case .hidden: L10n.text("Off", language: language)
        }
    }
}

enum SidebarPosition: String, CaseIterable, Identifiable {
    case left
    case right
    case bottom

    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .left: L10n.text("Left", language: language)
        case .right: L10n.text("Right", language: language)
        case .bottom: L10n.text("Bottom", language: language)
        }
    }
}

enum SidebarVerticalAlignment: String, CaseIterable, Identifiable {
    case top, center, bottom

    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .top: L10n.text("Top", language: language)
        case .center: L10n.text("Center", language: language)
        case .bottom: L10n.text("Bottom", language: language)
        }
    }
}

enum SidebarItemDisplayMode: String, CaseIterable, Identifiable {
    case icon
    case iconAndTitle

    var id: String { rawValue }
    func title(_ language: AppLanguage) -> String {
        L10n.text(self == .icon ? "Icons only" : "Icons and titles", language: language)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    nonisolated static let defaultSidebarWidth = 188.0
    nonisolated static let sidebarWidthRange = 94.0...376.0

    @Published private(set) var sidebarMode: SidebarVisibilityMode
    @Published private(set) var sidebarPosition: SidebarPosition
    @Published private(set) var sidebarItemDisplayMode: SidebarItemDisplayMode
    @Published private(set) var sidebarVerticalAlignment: SidebarVerticalAlignment
    @Published private(set) var sidebarWidth: Double
    @Published private(set) var showUngrouped: Bool
    @Published private(set) var showCreateGroup: Bool
    @Published private(set) var language: AppLanguage
    @Published private(set) var allWindowsShortcut: KeyboardShortcut
    @Published private(set) var currentAppShortcut: KeyboardShortcut
    @Published private(set) var sidebarShortcut: KeyboardShortcut?
    @Published private(set) var showWindowsFromAllDesktops: Bool
    @Published private(set) var showSidebarWindowsFromAllDesktops: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWindowsFromAllDesktops = defaults.object(forKey: "showWindowsFromAllDesktops") as? Bool ?? false
        showSidebarWindowsFromAllDesktops = defaults.object(forKey: "showSidebarWindowsFromAllDesktops") as? Bool ?? false
        func loadShortcut(_ key: String, fallback: KeyboardShortcut) -> KeyboardShortcut {
            guard let data = defaults.data(forKey: key),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
                  shortcut.isValid else { return fallback }
            return shortcut
        }
        let allWindows = loadShortcut("allWindowsShortcut", fallback: .allWindows)
        let currentApp = loadShortcut("currentAppShortcut", fallback: .currentApp)
        let conflict = allWindows.conflicts(with: currentApp)
        allWindowsShortcut = conflict ? .allWindows : allWindows
        currentAppShortcut = conflict ? .currentApp : currentApp
        let sidebar = loadShortcut("sidebarShortcut", fallback: .sidebar)
        sidebarShortcut = defaults.object(forKey: "sidebarShortcutEnabled") as? Bool == false
            || sidebar.conflicts(with: conflict ? .allWindows : allWindows)
            || sidebar.conflicts(with: conflict ? .currentApp : currentApp)
            ? nil : sidebar
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        sidebarMode = SidebarVisibilityMode(rawValue: defaults.string(forKey: "sidebarMode") ?? "") ?? .always
        sidebarVerticalAlignment = SidebarVerticalAlignment(
            rawValue: defaults.string(forKey: "sidebarVerticalAlignment") ?? ""
        ) ?? .center
        showUngrouped = defaults.object(forKey: "showUngrouped") as? Bool ?? true
        showCreateGroup = defaults.object(forKey: "showCreateGroup") as? Bool ?? true
        let savedWidth = defaults.object(forKey: "sidebarWidth") as? Double ?? Self.defaultSidebarWidth
        sidebarWidth = savedWidth.isFinite
            ? min(max(savedWidth, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
            : Self.defaultSidebarWidth
        sidebarItemDisplayMode = SidebarItemDisplayMode(
            rawValue: defaults.string(forKey: "sidebarItemDisplayMode") ?? ""
        ) ?? .iconAndTitle
        let savedPosition = defaults.string(forKey: "sidebarPosition")
        if let savedPosition, let position = SidebarPosition(rawValue: savedPosition) {
            sidebarPosition = position
        } else {
            sidebarPosition = .right
            if savedPosition != nil { defaults.set(SidebarPosition.right.rawValue, forKey: "sidebarPosition") }
        }
    }

    func setSidebarMode(_ mode: SidebarVisibilityMode) {
        sidebarMode = mode
        defaults.set(mode.rawValue, forKey: "sidebarMode")
    }

    func toggleSidebarMode() {
        switch sidebarMode {
        case .always: setSidebarMode(.hover)
        case .hover: setSidebarMode(.always)
        case .hidden: return
        }
    }

    func setSidebarPosition(_ position: SidebarPosition) {
        sidebarPosition = position
        defaults.set(position.rawValue, forKey: "sidebarPosition")
    }

    func setSidebarVerticalAlignment(_ alignment: SidebarVerticalAlignment) {
        sidebarVerticalAlignment = alignment
        defaults.set(alignment.rawValue, forKey: "sidebarVerticalAlignment")
    }

    func setShowUngrouped(_ show: Bool) {
        showUngrouped = show
        defaults.set(show, forKey: "showUngrouped")
    }

    func setSidebarWidth(_ width: Double) {
        guard width.isFinite else { return }
        sidebarWidth = min(max(width, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        defaults.set(sidebarWidth, forKey: "sidebarWidth")
    }

    func setShowCreateGroup(_ show: Bool) {
        showCreateGroup = show
        defaults.set(show, forKey: "showCreateGroup")
    }

    func setSidebarItemDisplayMode(_ mode: SidebarItemDisplayMode) {
        sidebarItemDisplayMode = mode
        defaults.set(mode.rawValue, forKey: "sidebarItemDisplayMode")
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: "language")
    }

    func setShowWindowsFromAllDesktops(_ enabled: Bool) {
        showWindowsFromAllDesktops = enabled
        defaults.set(enabled, forKey: "showWindowsFromAllDesktops")
    }

    func setShowSidebarWindowsFromAllDesktops(_ enabled: Bool) {
        showSidebarWindowsFromAllDesktops = enabled
        defaults.set(enabled, forKey: "showSidebarWindowsFromAllDesktops")
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcut, target: ShortcutTarget) -> Bool {
        let others = ShortcutTarget.allCases.filter { $0 != target }.compactMap { self.shortcut(for: $0) }
        guard shortcut.isValid, !others.contains(where: { shortcut.conflicts(with: $0) }),
              let data = try? JSONEncoder().encode(shortcut) else { return false }
        switch target {
        case .allWindows: allWindowsShortcut = shortcut
        case .currentApp: currentAppShortcut = shortcut
        case .sidebar:
            sidebarShortcut = shortcut
            defaults.set(true, forKey: "sidebarShortcutEnabled")
        }
        defaults.set(data, forKey: target.rawValue + "Shortcut")
        return true
    }

    func shortcut(for target: ShortcutTarget) -> KeyboardShortcut? {
        switch target {
        case .allWindows: allWindowsShortcut
        case .currentApp: currentAppShortcut
        case .sidebar: sidebarShortcut
        }
    }

    func disableSidebarShortcut() {
        sidebarShortcut = nil
        defaults.set(false, forKey: "sidebarShortcutEnabled")
    }

    func resetShortcuts() {
        allWindowsShortcut = .allWindows
        currentAppShortcut = .currentApp
        sidebarShortcut = .sidebar
        defaults.removeObject(forKey: "allWindowsShortcut")
        defaults.removeObject(forKey: "currentAppShortcut")
        defaults.removeObject(forKey: "sidebarShortcut")
        defaults.removeObject(forKey: "sidebarShortcutEnabled")
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case sidebar = "Sidebar"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .sidebar: "sidebar.left"
        case .shortcuts: "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowService: WindowService
    @ObservedObject var groupStore: GroupStore
    @ObservedObject var shortcuts: ShortcutController
    @State var page: SettingsPage = .general

    private var language: AppLanguage { settings.language }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page) {
                navigationItem(.general)
                navigationItem(.sidebar)
                navigationItem(.shortcuts)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch page {
                    case .general: generalSettings
                    case .sidebar: sidebarSettings
                    case .shortcuts: shortcutSettings
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(.system(size: 13))
        .tint(Color(nsColor: appAccentColor))
        .frame(width: 840, height: 600)
        .onChange(of: page) { _ in shortcuts.cancelRecording() }
        .onDisappear { shortcuts.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            shortcuts.cancelRecording()
        }
    }

    private func navigationItem(_ destination: SettingsPage) -> some View {
        Label(L10n.text(destination.rawValue, language: language), systemImage: destination.symbol)
            .font(.system(size: 14))
            .padding(.vertical, 5)
            .tag(destination)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(L10n.text(title, language: language) + ":")
                .multilineTextAlignment(.trailing)
                .frame(width: 130, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSettings: some View {
        Group {
            settingsRow("Window switcher") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L10n.text("Show windows from all desktops", language: language), isOn: Binding(
                        get: { settings.showWindowsFromAllDesktops }, set: settings.setShowWindowsFromAllDesktops
                    ))
                    Text(L10n.text("The current desktop comes first in recent order. Other desktops stay grouped in a stable order.", language: language))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }
            settingsRow("Language") {
                Picker(L10n.text("Language", language: language), selection: Binding(
                    get: { settings.language }, set: settings.setLanguage
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option == .system ? L10n.text("System", language: language) : option.name).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            settingsRow("Accessibility") {
                HStack {
                    Text(L10n.text(windowService.hasAccessibility ? "Granted" : "Not granted", language: language))
                    if !windowService.hasAccessibility {
                        Button(L10n.text("Request access", language: language)) { windowService.requestAccessibility() }
                    }
                }
            }
            settingsRow("Global shortcuts") {
                HStack {
                    Text(L10n.text(shortcuts.isRunning ? "Running" : "Not running", language: language))
                    if windowService.hasAccessibility && !shortcuts.isRunning {
                        Button(L10n.text("Retry", language: language)) { _ = shortcuts.start() }
                    }
                }
            }
            if let detail = groupStore.persistenceErrorDetail,
               let operation = groupStore.persistenceErrorOperation {
                settingsRow("Groups") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.format(operation == .read ? "Could not read group data: %@" : "Could not save group data: %@",
                                         detail, language: language))
                            .foregroundStyle(.red)
                        if operation == .read, let backup = groupStore.persistenceBackupURL {
                            Text(L10n.format("The unreadable file was moved to %@.", backup.path, language: language))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var sidebarSettings: some View {
        Group {
            settingsRow("Sidebar") {
                Picker(L10n.text("Sidebar", language: language), selection: Binding(
                    get: { settings.sidebarMode }, set: settings.setSidebarMode
                )) {
                    ForEach(SidebarVisibilityMode.allCases) { mode in
                        Text(mode.title(language)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            settingsRow("Sidebar position") {
                Picker(L10n.text("Sidebar position", language: language), selection: Binding(
                    get: { settings.sidebarPosition }, set: settings.setSidebarPosition
                )) {
                    ForEach(SidebarPosition.allCases) { position in
                        Text(position.title(language)).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            if settings.sidebarPosition != .bottom {
                settingsRow("Vertical alignment") {
                    Picker(L10n.text("Vertical alignment", language: language), selection: Binding(
                        get: { settings.sidebarVerticalAlignment }, set: settings.setSidebarVerticalAlignment
                    )) {
                        ForEach(SidebarVerticalAlignment.allCases) { alignment in
                            Text(alignment.title(language)).tag(alignment)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }
            }
            settingsRow("Display") {
                Picker(L10n.text("Display", language: language), selection: Binding(
                    get: { settings.sidebarItemDisplayMode }, set: settings.setSidebarItemDisplayMode
                )) {
                    ForEach(SidebarItemDisplayMode.allCases) { mode in
                        Text(mode.title(language)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            if settings.sidebarPosition != .bottom {
                settingsRow("Sidebar width") {
                    HStack(spacing: 12) {
                        SidebarWidthSlider(
                            value: Binding(get: { settings.sidebarWidth }, set: settings.setSidebarWidth),
                            language: language
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        Button {
                            settings.setSidebarWidth(AppSettings.defaultSidebarWidth)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .help(L10n.text("Restore defaults", language: language))
                        .accessibilityLabel(L10n.text("Restore defaults", language: language))
                    }
                    .disabled(settings.sidebarItemDisplayMode == .icon)
                }
            }
            settingsRow("Desktops") {
                Toggle(L10n.text("Show windows from all desktops", language: language), isOn: Binding(
                    get: { settings.showSidebarWindowsFromAllDesktops }, set: settings.setShowSidebarWindowsFromAllDesktops
                ))
                .toggleStyle(.checkbox)
            }
            settingsRow("Groups") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.text("Show Ungrouped (hidden when empty)", language: language), isOn: Binding(
                        get: { settings.showUngrouped }, set: settings.setShowUngrouped
                    ))
                    Toggle(L10n.text("Show New Group button", language: language), isOn: Binding(
                        get: { settings.showCreateGroup }, set: settings.setShowCreateGroup
                    ))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var shortcutSettings: some View {
        Group {
            ForEach(ShortcutTarget.allCases, id: \.self) { target in
                settingsRow(target.title) {
                    HStack {
                        shortcutButton(target: target)
                        if target == .sidebar, settings.sidebarShortcut != nil {
                            Button(L10n.text("Disable", language: language)) {
                                shortcuts.cancelRecording()
                                settings.disableSidebarShortcut()
                            }
                        }
                    }
                }
            }
            settingsRow("Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Click a shortcut to record. Esc cancels; Shift switches backward.", language: language))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("Restore defaults", language: language)) {
                        shortcuts.cancelRecording()
                        settings.resetShortcuts()
                    }
                    if let error = shortcuts.recordingErrorKey {
                        Text(L10n.text(error, language: language)).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func shortcutButton(target: ShortcutTarget) -> some View {
        let recording = shortcuts.recordingTarget == target
        let display = settings.shortcut(for: target)?.display ?? L10n.text("Off", language: language)
        return Button(recording ? L10n.text("Press shortcut…", language: language) : display) {
            if recording {
                shortcuts.cancelRecording()
            } else {
                shortcuts.beginRecording(target: target) { shortcut in
                    settings.setShortcut(shortcut, target: target)
                }
            }
        }
        .accessibilityLabel(L10n.text(target.title, language: language))
        .accessibilityValue(recording ? L10n.text("Press shortcut…", language: language) : display)
    }
}

struct SidebarWidthSlider: NSViewRepresentable {
    @Binding var value: Double
    var language: AppLanguage

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider { makeControl(coordinator: context.coordinator) }

    func makeControl(coordinator: Coordinator) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.cell = WidthSliderCell()
        slider.minValue = AppSettings.sidebarWidthRange.lowerBound
        slider.maxValue = AppSettings.sidebarWidthRange.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(L10n.text("Sidebar width", language: language))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(L10n.text("Sidebar width", language: language))
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue.rounded() }
    }

    private final class WidthSliderCell: NSSliderCell {
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let knob = knobRect(flipped: flipped)
            let track = NSRect(x: rect.minX + knob.width / 2, y: knob.midY - 4,
                               width: max(0, rect.width - knob.width), height: 8)
            appAccentColor.withAlphaComponent(isEnabled ? 0.18 : 0.08).setFill()
            NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
            let filled = NSRect(x: track.minX, y: track.minY,
                                width: min(max(0, knob.midX - track.minX), track.width), height: track.height)
            appAccentColor.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill()
        }

        override func drawKnob(_ knobRect: NSRect) {
            let knob = NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 8, y: knobRect.midY - 8, width: 16, height: 16))
            NSColor.windowBackgroundColor.setFill()
            knob.fill()
            appAccentColor.withAlphaComponent(isEnabled ? 1 : 0.3).setStroke()
            knob.lineWidth = 2
            knob.stroke()
        }
    }
}
