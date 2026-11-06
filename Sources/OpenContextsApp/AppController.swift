import AppKit
import Combine
import OpenContextsCore
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let settingsWindowID = "local:settings"
    private let windowService = WindowService()
    private let groupStore = GroupStore()
    private let shortcuts = ShortcutController()
    private let settings = AppSettings()

    private var sidebars: [CGDirectDisplayID: SidebarPanel] = [:]
    private var switchers: [CGDirectDisplayID: SwitcherPanel] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusMenuLanguage: AppLanguage?
    private var groupFlushTimer: Timer?

    private var switchingResults: [WindowSearch.Match] = []
    private var switchingWindowCount = 0
    private var searchQuery = ""
    private var selectionBeforeSearch: String?
    private var selectedIndex = 0
    private var currentAppOnly: Bool?
    private var currentAppPID: pid_t?
    private var didRestoreGroups = false

    private var includesWindowsFromAllDesktops: Bool {
        settings.showWindowsFromAllDesktops || settings.showSidebarWindowsFromAllDesktops
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        configureShortcuts()
        observeState()
        rebuildPanels()
        windowService.setIncludeAllSpaces(includesWindowsFromAllDesktops)
        windowService.start()
        startGroupFlushTimer()
        if !windowService.hasAccessibility { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        groupFlushTimer?.invalidate()
        groupStore.flushPendingChanges()
        groupStore.waitForPendingWrites()
        shortcuts.stop()
        windowService.stop()
        sidebars.values.forEach { $0.close() }
        switchers.values.forEach { $0.close() }
    }

    // Live refreshes only update saved titles in memory; write them out periodically instead of every scan.
    private func startGroupFlushTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.groupStore.flushPendingChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        groupFlushTimer = timer
    }

    private func configureShortcuts() {
        shortcuts.configure(allWindows: settings.allWindowsShortcut, currentApp: settings.currentAppShortcut,
                            sidebar: settings.sidebarShortcut)
        shortcuts.canBegin = { [weak self] currentAppOnly in
            self?.availableWindows(currentAppOnly: currentAppOnly).isEmpty == false
        }
        shortcuts.onAction = { [weak self] action in self?.handle(action) }
    }

    private func observeState() {
        windowService.$windows.sink { [weak self] windows in
            guard let self else { return }
            if self.windowService.hasCompletedInitialScan && !self.didRestoreGroups {
                self.didRestoreGroups = true
                self.groupStore.reconcile(windows)
            } else {
                self.groupStore.updateLiveWindows(windows)
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateSidebars()
                self?.refreshVisibleSwitcher()
            }
        }.store(in: &cancellables)

        windowService.$fullscreenScreenIDs.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSidebars() }
        }
            .store(in: &cancellables)

        windowService.$appBadges.removeDuplicates().sink { [weak self] badges in
            self?.sidebars.values.forEach { $0.updateBadges(badges) }
        }.store(in: &cancellables)

        windowService.$focusedWindowID.removeDuplicates().sink { [weak self] id in
            self?.sidebars.values.forEach { $0.updateFocusedWindow(id) }
        }.store(in: &cancellables)

        windowService.$hasAccessibility.removeDuplicates().sink { [weak self] trusted in
            guard let self else { return }
            if trusted { _ = self.shortcuts.start() } else { self.shortcuts.stop() }
        }.store(in: &cancellables)

        groupStore.$revision.dropFirst().sink { [weak self] _ in self?.updateSidebars() }
            .store(in: &cancellables)

        // objectWillChange fires before the new value is stored, so read settings on the next turn.
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateSidebars()
                self?.configureMenuBar()
                if let self {
                    self.shortcuts.configure(allWindows: self.settings.allWindowsShortcut,
                                             currentApp: self.settings.currentAppShortcut,
                                             sidebar: self.settings.sidebarShortcut)
                    self.windowService.setIncludeAllSpaces(self.includesWindowsFromAllDesktops)
                    self.settingsWindow?.title = L10n.text("OtherContexts Settings", language: self.settings.language)
                    if self.currentAppOnly != nil { self.refreshVisibleSwitcher() }
                }
            }
        }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
    }

    private func rebuildPanels() {
        sidebars.values.forEach { $0.close() }
        switchers.values.forEach { $0.close() }
        sidebars = [:]
        switchers = [:]

        for screen in NSScreen.screens {
            let id = Self.displayID(for: screen)
            sidebars[id] = SidebarPanel(
                screen: screen,
                onActivate: { [weak self] in self?.windowService.activate($0) },
                canCloseWindow: { [weak self] id, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    self.windowService.canClose(id) { completion($0) }
                },
                onCloseWindow: { [weak self] in self?.windowService.close($0) },
                windowPinPosition: { [weak self] in self?.groupStore.pinPosition(id: $0) },
                onTogglePin: { [weak self] in self?.groupStore.togglePin(id: $0) },
                onMoveWindow: { [weak self] id, groupID, beforeID, order in
                    self?.groupStore.moveWindow(id: id, to: groupID, before: beforeID,
                                                visibleOrderByGroup: order)
                },
                onMoveGroup: { [weak self] id, beforeID in
                    self?.groupStore.moveGroup(id: id, before: beforeID)
                },
                onCreateGroup: { [weak self] in self?.groupStore.createGroup(name: $0) },
                onRenameGroup: { [weak self] id, name in self?.groupStore.renameGroup(id: id, name: name) },
                onDeleteGroup: { [weak self] in self?.groupStore.deleteGroup(id: $0) },
                onResize: { [weak self] in self?.settings.setSidebarWidth(Double($0)) }
            )
            switchers[id] = SwitcherPanel(
                screen: screen,
                onActivate: { [weak self] id in self?.finishSwitcher(activating: id) },
                onSelect: { [weak self] id in self?.selectSwitcherWindow(id: id) }
            )
        }
        updateSidebars()
        if currentAppOnly != nil {
            switchers.values.forEach {
                $0.show(results: switchingResults, selectedIndex: selectedIndex, query: searchQuery,
                        groupBySpace: settings.showWindowsFromAllDesktops,
                        totalWindowCount: switchingWindowCount, language: settings.language)
            }
        }
    }

    private func updateSidebars() {
        let windowsByGroup = Dictionary(uniqueKeysWithValues: groupStore.groups.map {
            ($0.id, groupStore.windows(in: $0.id).onVisibleSpaces(allSpaces: settings.showSidebarWindowsFromAllDesktops))
        })
        for (id, panel) in sidebars {
            panel.update(
                groups: groupStore.groups,
                windowsByGroup: windowsByGroup,
                alwaysVisible: settings.sidebarMode == .always,
                fullscreen: windowService.fullscreenScreenIDs.contains(id),
                enabled: settings.sidebarMode != .hidden,
                showUngrouped: settings.showUngrouped,
                showCreateGroup: settings.showCreateGroup,
                verticalAlignment: settings.sidebarVerticalAlignment,
                sidebarWidth: CGFloat(settings.sidebarWidth),
                position: settings.sidebarPosition,
                itemDisplayMode: settings.sidebarItemDisplayMode,
                language: settings.language
            )
            panel.updateBadges(windowService.appBadges)
            panel.updateFocusedWindow(windowService.focusedWindowID)
        }
    }

    private func availableWindows(currentAppOnly: Bool, pid: pid_t? = nil) -> [WindowInfo] {
        let windows = windowService.windows.filter { settings.showWindowsFromAllDesktops || $0.isOnCurrentSpace }
        guard currentAppOnly else { return windows }
        let processID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return windows.filter { $0.processID == processID }
    }

    private func handle(_ action: SwitcherAction) {
        windowService.cancelActivation()
        switch action {
        case .toggleSidebar:
            finishSwitcher(activating: nil)
            settings.toggleSidebarMode()
        case let .begin(currentAppOnly, reverse):
            searchQuery = ""
            selectionBeforeSearch = nil
            self.currentAppOnly = currentAppOnly
            currentAppPID = currentAppOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
            switchingResults = WindowSwitcher.filter(availableWindows(currentAppOnly: currentAppOnly, pid: currentAppPID),
                                                     query: "", allSpaces: settings.showWindowsFromAllDesktops)
            switchingWindowCount = switchingResults.count
            guard !switchingResults.isEmpty else { return }
            let firstIsFocused = switchingResults.first?.window.id == windowService.focusedWindowID
            selectedIndex = SwitcherSelection.initial(count: switchingResults.count, firstIsFocused: firstIsFocused,
                                                      reverse: reverse)
            switchers.values.forEach {
                $0.show(results: switchingResults, selectedIndex: selectedIndex,
                        groupBySpace: settings.showWindowsFromAllDesktops,
                        totalWindowCount: switchingWindowCount, language: settings.language)
            }
        case let .step(amount):
            guard !switchingResults.isEmpty else { return }
            selectedIndex = SwitcherSelection.stepped(selectedIndex, by: amount, count: switchingResults.count)
            updateSwitchers(resetHover: true)
        case let .search(query):
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let currentAppOnly else { return }
            if searchQuery.isEmpty {
                selectionBeforeSearch = switchingResults.indices.contains(selectedIndex)
                    ? switchingResults[selectedIndex].window.id : nil
            }
            searchQuery = query
            let windows = availableWindows(currentAppOnly: currentAppOnly, pid: currentAppPID)
            switchingWindowCount = windows.count
            guard !windows.isEmpty else { finishSwitcher(activating: nil); return }
            switchingResults = WindowSwitcher.filter(windows, query: query, allSpaces: settings.showWindowsFromAllDesktops)
            selectedIndex = query.isEmpty
                ? SwitcherSelection.preserved(selectionBeforeSearch, in: switchingResults.map(\.window.id), fallback: 0)
                : 0
            updateSwitchers(resetHover: true)
        case .commit:
            let id = switchingResults.indices.contains(selectedIndex) ? switchingResults[selectedIndex].window.id : nil
            finishSwitcher(activating: id)
        case .cancel:
            finishSwitcher(activating: nil)
        }
    }

    private func refreshVisibleSwitcher() {
        guard let currentAppOnly else { return }
        let selectedID = switchingResults.indices.contains(selectedIndex) ? switchingResults[selectedIndex].window.id : nil
        let windows = availableWindows(currentAppOnly: currentAppOnly, pid: currentAppPID)
        switchingWindowCount = windows.count
        guard !windows.isEmpty else {
            finishSwitcher(activating: nil)
            return
        }
        switchingResults = WindowSwitcher.filter(windows, query: searchQuery, allSpaces: settings.showWindowsFromAllDesktops)
        selectedIndex = SwitcherSelection.preserved(selectedID, in: switchingResults.map(\.window.id),
                                                    fallback: selectedIndex)
        updateSwitchers()
    }

    private func selectSwitcherWindow(id: String) {
        guard currentAppOnly != nil,
              let index = switchingResults.firstIndex(where: { $0.window.id == id }),
              index != selectedIndex else { return }
        selectedIndex = index
        updateSwitchers()
    }

    private func updateSwitchers(resetHover: Bool = false) {
        switchers.values.forEach {
            $0.update(results: switchingResults, selectedIndex: selectedIndex, resetHover: resetHover,
                      groupBySpace: settings.showWindowsFromAllDesktops,
                      query: searchQuery, totalWindowCount: switchingWindowCount, language: settings.language)
        }
    }

    private func finishSwitcher(activating id: String?) {
        shortcuts.resetState()
        switchers.values.forEach { $0.hideSwitcher() }
        switchingResults = []
        switchingWindowCount = 0
        searchQuery = ""
        selectionBeforeSearch = nil
        selectedIndex = 0
        currentAppOnly = nil
        currentAppPID = nil
        if let id { windowService.activate(id) }
    }

    private func configureMenuBar() {
        // Runs on every settings change, e.g. each tick of the width slider; the menu only depends on the language.
        guard statusItem == nil || statusMenuLanguage != settings.language else { return }
        statusMenuLanguage = settings.language
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "OtherContexts")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("OtherContexts")
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("Settings…", language: settings.language), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.text("Grant Accessibility Access…", language: settings.language), action: #selector(requestAccessibility), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("Quit OtherContexts", language: settings.language), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(
                settings: settings,
                windowService: windowService,
                groupStore: groupStore,
                shortcuts: shortcuts
            ))
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.text("OtherContexts Settings", language: settings.language)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        Activation.activateSelf()
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let settingsWindow {
            windowService.registerLocalWindow(settingsWindow, id: Self.settingsWindowID)
        }
    }

    @objc private func requestAccessibility() {
        windowService.requestAccessibility()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        shortcuts.cancelRecording()
        windowService.unregisterLocalWindow(id: Self.settingsWindowID)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        shortcuts.cancelRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        windowService.registerLocalWindow(window, id: Self.settingsWindowID)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
