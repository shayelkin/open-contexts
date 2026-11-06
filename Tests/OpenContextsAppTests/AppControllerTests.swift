import AppKit
import OpenContextsCore
import Testing
import XCTest
@testable import OpenContextsApp

@MainActor
final class AppControllerTests: XCTestCase {
    private final class Trust {
        var value = false
    }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    nonisolated private static let editorID = "com.example.Editor"
    private static let settingsID = "local:settings"

    private var suite = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var trust = Trust()
    private var service: WindowService!
    private var store: GroupStore!
    private var shortcuts: ShortcutController!
    private var settings: AppSettings!
    private var controller: AppController!
    private var frontmostPID: pid_t?
    private var terminations = 0
    private var launched = false
    private var ownedWindows: [NSWindow] = []
    private var orphanedPanels: [NSWindow] = []

    private var fileURL: URL { directory.appendingPathComponent("groups.json") }
    private var sidebars: [SidebarPanel] { Array(controller.sidebars.values) }
    private var switchers: [SwitcherPanel] { Array(controller.switchers.values) }
    private var resultIDs: [String] { controller.switchingResults.map(\.window.id) }
    private var selectedID: String? {
        controller.switchingResults.indices.contains(controller.selectedIndex)
            ? controller.switchingResults[controller.selectedIndex].window.id : nil
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "the controller needs a display for its panels")
        suite = "OpenContexts.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        trust = Trust()
        frontmostPID = nil
        terminations = 0
        launched = false
        ownedWindows = []
        orphanedPanels = []
    }

    override func tearDown() async throws {
        if let controller {
            if launched { controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
            controller.settingsWindow?.close()
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        service?.stop()
        ownedWindows.forEach { $0.close() }
        orphanedPanels.forEach { $0.close() }
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func makeController() {
        let trust = trust
        service = WindowService(isTrusted: { trust.value })
        store = GroupStore(fileURL: fileURL)
        shortcuts = ShortcutController()
        settings = AppSettings(defaults: defaults)
        controller = AppController(
            windowService: service, groupStore: store, shortcuts: shortcuts, settings: settings,
            frontmostProcessID: { [unowned self] in self.frontmostPID },
            terminate: { [unowned self] in self.terminations += 1 }
        )
    }

    /// Launches without Accessibility so no real scan starts, then closes the settings window that
    /// an untrusted launch opens and stops the scan timer, so only synthetic scans reach the controller.
    private func launch(trusted: Bool = true) async {
        makeController()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        launched = true
        service.stop()
        controller.settingsWindow?.close()
        trust.value = trusted
        await settle()
    }

    private func settle() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// Waits for a real scan started by `WindowService.refresh()` to finish and be applied.
    private func finishRealScan() async {
        await withCheckedContinuation { continuation in service.scanQueue.async { continuation.resume() } }
        await settle()
    }

    private func window(_ id: String, app: String = "Editor", appID: String = editorID, title: String? = nil,
                        pid: pid_t = 0, space: WindowSpace? = nil) -> WindowService.TrackedWindow {
        WindowService.TrackedWindow(
            id: id, element: AXUIElementCreateApplication(0),
            info: WindowInfo(id: id, appID: appID, appName: app, title: title ?? id, processID: pid, space: space)
        )
    }

    private func scan(_ windows: [WindowService.TrackedWindow], focusedID: String? = nil,
                      fullscreen: Set<UInt32> = [], badges: [String: DockBadgeRead]? = nil) async {
        service.apply(WindowService.ScanResult(
            windows: windows, focusedID: focusedID, fullscreenScreenIDs: fullscreen,
            activeAppIDs: Set(windows.map(\.info.appID)), badgeReads: badges
        ))
        await settle()
    }

    private func localWindow(_ id: String, title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        ownedWindows.append(window)
        service.registerLocalWindow(window, id: id)
        return window
    }

    private func act(_ action: SwitcherAction) async {
        shortcuts.onAction?(action)
        await settle()
    }

    private func menuTitles() -> [String] {
        controller.statusItem?.menu?.items.map(\.title) ?? []
    }

    private func fileText() throws -> String {
        store.waitForPendingWrites()
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func rowOrder(_ panel: SidebarPanel) -> [String] {
        panel.smokeVisibleRowOrder
    }

    private func notification(_ name: Notification.Name, _ object: NSWindow?) -> Notification {
        Notification(name: name, object: object)
    }

    // MARK: - Launch and termination

    func testUntrustedLaunchShowsSettingsMenuBarAndPanelsWithoutStartingShortcuts() async throws {
        makeController()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        launched = true
        service.stop()
        await settle()

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        let settingsWindow = try XCTUnwrap(controller.settingsWindow, "an untrusted launch did not open Settings")
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(settingsWindow.title, L10n.text("OtherContexts Settings", language: settings.language))
        XCTAssertTrue(settingsWindow.delegate === controller)
        XCTAssertFalse(settingsWindow.isReleasedWhenClosed)
        XCTAssertEqual(service.windows.map(\.id), [Self.settingsID])

        let menu = try XCTUnwrap(controller.statusItem?.menu)
        XCTAssertEqual(menuTitles(), [
            L10n.text("Settings…", language: settings.language),
            L10n.text("Grant Accessibility Access…", language: settings.language),
            "",
            L10n.text("Quit OtherContexts", language: settings.language)
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].keyEquivalent, "q")
        XCTAssertTrue([0, 1, 3].allSatisfy { menu.items[$0].target === controller })
        XCTAssertEqual(controller.statusItem?.button?.accessibilityLabel(), "OtherContexts")
        XCTAssertEqual(controller.statusItem?.button?.image?.isTemplate, true)

        let timer = try XCTUnwrap(controller.groupFlushTimer)
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.timeInterval, 5)

        XCTAssertEqual(controller.sidebars.count, NSScreen.screens.count)
        XCTAssertEqual(Set(controller.switchers.keys), Set(controller.sidebars.keys))
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
        XCTAssertFalse(shortcuts.isRunning)
        XCTAssertNil(controller.currentAppOnly)
    }

    func testTrustedLaunchSkipsSettingsAndTrustChangesStartAndStopShortcuts() async throws {
        trust.value = true
        makeController()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        launched = true
        service.stop()
        await finishRealScan()

        XCTAssertNil(controller.settingsWindow, "a trusted launch opened Settings")
        XCTAssertTrue(service.hasAccessibility)
        XCTAssertEqual(shortcuts.isRunning, AXIsProcessTrusted(),
                       "shortcuts did not follow the Accessibility state")

        trust.value = false
        await scan([])
        XCTAssertFalse(shortcuts.isRunning, "losing Accessibility did not stop the shortcuts")
        trust.value = true
        await scan([])
        XCTAssertEqual(shortcuts.isRunning, AXIsProcessTrusted())
    }

    func testTerminationFlushesGroupsAndStopsEverything() async throws {
        await launch()
        await scan([window("a", title: "Draft"), window("b", title: "Other")])
        store.createGroup(name: "Work")
        let work = try XCTUnwrap(store.groups.last?.id)
        store.moveWindow(id: "a", to: work)
        await scan([window("a", title: "Draft (edited)"), window("b", title: "Other")])
        XCTAssertTrue(store.hasPendingChanges)
        XCTAssertFalse(try fileText().contains("Draft (edited)"))
        let timer = try XCTUnwrap(controller.groupFlushTimer)
        await act(.begin(currentAppOnly: false, reverse: false))
        XCTAssertTrue(switchers.allSatisfy(\.isVisible))

        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        launched = false

        XCTAssertFalse(timer.isValid)
        XCTAssertFalse(store.hasPendingChanges)
        XCTAssertTrue(try fileText().contains("Draft (edited)"), "termination lost a pending title change")
        XCTAssertFalse(shortcuts.isRunning)
        XCTAssertTrue(sidebars.allSatisfy { !$0.isVisible })
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
    }

    func testFlushTimerWritesLiveTitleChanges() async throws {
        await launch()
        await scan([window("a", title: "Inbox (1)")])
        store.createGroup(name: "Mail")
        let mail = try XCTUnwrap(store.groups.last?.id)
        store.moveWindow(id: "a", to: mail)
        await scan([window("a", title: "Inbox (9)")])
        XCTAssertTrue(store.hasPendingChanges)

        controller.groupFlushTimer?.fire()
        XCTAssertFalse(store.hasPendingChanges)
        XCTAssertTrue(try fileText().contains("Inbox (9)"))
        XCTAssertTrue(controller.groupFlushTimer?.isValid == true, "firing stopped the repeating timer")
    }

    // MARK: - Window scans and the sidebar

    func testOnlyTheFirstCompletedScanReconcilesGroups() async throws {
        await launch()
        let launchRevision = store.revision
        _ = localWindow("local:early", title: "Early")
        await settle()
        XCTAssertEqual(store.revision, launchRevision, "a window published before the first scan reconciled")
        XCTAssertEqual(store.windows(in: GroupStore.ungroupedID).map(\.id), ["local:early"])
        service.unregisterLocalWindow(id: "local:early")

        await scan([window("a")])
        XCTAssertEqual(store.revision, launchRevision + 1, "the first scan did not reconcile the groups")

        await scan([window("a"), window("b")])
        await scan([window("b")])
        XCTAssertEqual(store.revision, launchRevision + 1, "a later scan reconciled instead of refreshing")
        XCTAssertEqual(store.windows(in: GroupStore.ungroupedID).map(\.id), ["b"])
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:b"]) }
    }

    func testFirstScanRestoresSavedGroups() async throws {
        let previous = GroupStore(fileURL: fileURL)
        previous.reconcile([WindowInfo(id: "old", appID: Self.editorID, appName: "Editor", title: "Report", processID: 1)])
        previous.createGroup(name: "Work")
        let work = try XCTUnwrap(previous.groups.last?.id)
        previous.moveWindow(id: "old", to: work)
        previous.waitForPendingWrites()

        await launch()
        await scan([window("new", title: "Report"), window("loose", title: "Loose")])
        XCTAssertEqual(store.windows(in: work).map(\.id), ["new"])
        sidebars.forEach {
            XCTAssertEqual(rowOrder($0), ["w:loose", "g:\(work)", "w:new"])
        }
    }

    func testSidebarsFollowFocusBadgesAndFullscreen() async throws {
        await launch()
        let fullscreenID = try XCTUnwrap(controller.sidebars.keys.first)
        await scan([window("a"), window("b")], focusedID: "b", fullscreen: [fullscreenID],
                   badges: [Self.editorID: .value("3")])

        for (id, panel) in controller.sidebars {
            let rows = panel.sidebarRows.filter { if case .window = $0.style { return true }; return false }
            XCTAssertEqual(rows.filter(\.selected).map(\.titleLabel.stringValue), ["b"])
            XCTAssertTrue(rows.allSatisfy { $0.badgeLabel?.isHidden == false && $0.badgeLabel?.stringValue == "3" })
            XCTAssertEqual(panel.revealTarget, id == fullscreenID ? 0 : 1,
                           "only the full-screen display should hide its sidebar")
        }

        await scan([window("a"), window("b")], focusedID: "a", badges: [Self.editorID: .value(nil)])
        for panel in sidebars {
            let rows = panel.sidebarRows.filter { if case .window = $0.style { return true }; return false }
            XCTAssertEqual(rows.filter(\.selected).map(\.titleLabel.stringValue), ["a"])
            XCTAssertTrue(rows.allSatisfy { $0.badgeLabel?.isHidden != false }, "a cleared badge stayed visible")
            XCTAssertEqual(panel.revealTarget, 1)
        }
    }

    func testSidebarsFollowSettings() async throws {
        await launch()
        let other = WindowSpace(id: 2, index: 2, isCurrent: false, desktopNumber: 2)
        let windows = [window("here"), window("there", space: other)]
        await scan(windows)
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:here"]) }

        settings.setShowSidebarWindowsFromAllDesktops(true)
        await settle()
        await finishRealScan()
        await scan(windows)
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:here", "w:there"]) }

        settings.setSidebarPosition(.left)
        settings.setLanguage(.fr)
        settings.setSidebarWidth(250)
        await settle()
        for panel in sidebars {
            XCTAssertEqual(panel.position, .left)
            XCTAssertEqual(panel.language, .fr)
            XCTAssertEqual(panel.sidebarFrames().expanded.width, 250)
        }

        settings.setSidebarMode(.hidden)
        await settle()
        for panel in sidebars {
            XCTAssertFalse(panel.isVisible, "an off sidebar stayed on screen")
            XCTAssertEqual(panel.revealTarget, 0)
        }
        await act(.toggleSidebar)
        XCTAssertEqual(settings.sidebarMode, .hidden, "the shortcut turned on a sidebar that is off")

        settings.setSidebarMode(.always)
        await settle()
        XCTAssertTrue(sidebars.allSatisfy { $0.isVisible && $0.revealTarget == 1 })
        await act(.toggleSidebar)
        XCTAssertEqual(settings.sidebarMode, .hover)
        XCTAssertTrue(sidebars.allSatisfy { $0.revealTarget == 0 }, "show on hover kept the sidebar expanded")
    }

    func testSidebarCallbacksEditGroupsAndSettings() async throws {
        await launch()
        await scan([window("a"), window("b"), window("c")])
        let panel = try XCTUnwrap(sidebars.first)
        let ungrouped = GroupStore.ungroupedID

        panel.onCreateGroup("Work")
        await settle()
        let work = try XCTUnwrap(store.groups.last { $0.name == "Work" }?.id)
        sidebars.forEach { XCTAssertTrue(rowOrder($0).contains("g:\(work)"), "a new group did not reach the sidebar") }

        panel.onRenameGroup(work, "Projects")
        XCTAssertEqual(store.groups.first { $0.id == work }?.name, "Projects")

        panel.onMoveWindow("b", work, nil, [ungrouped: ["a", "b", "c"], work: []])
        await settle()
        XCTAssertEqual(store.windows(in: work).map(\.id), ["b"])
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:a", "w:c", "g:\(work)", "w:b"]) }

        panel.onCreateGroup("Home")
        await settle()
        let home = try XCTUnwrap(store.groups.last { $0.name == "Home" }?.id)
        panel.onMoveGroup(home, work)
        await settle()
        XCTAssertEqual(store.groups.map(\.id), [ungrouped, home, work])
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:a", "w:c", "g:\(home)", "g:\(work)", "w:b"]) }

        XCTAssertNil(panel.windowPinPosition("c"))
        panel.onTogglePin("c")
        XCTAssertNotNil(panel.windowPinPosition("c"))
        XCTAssertEqual(panel.windowPinPosition("c"), store.pinPosition(id: "c"))
        panel.onTogglePin("c")
        XCTAssertNil(panel.windowPinPosition("c"))

        panel.onDeleteGroup(work)
        await settle()
        XCTAssertFalse(store.groups.contains { $0.id == work })
        XCTAssertEqual(Set(store.windows(in: ungrouped).map(\.id)), ["a", "b", "c"])

        panel.onResize(301)
        XCTAssertEqual(settings.sidebarWidth, 301)
        panel.onResize(10_000)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.sidebarWidthRange.upperBound)
    }

    func testSidebarCallbacksActivateAndCloseWindows() async throws {
        await launch()
        let local = localWindow("local:fixture", title: "Fixture")
        await settle()
        let panel = try XCTUnwrap(sidebars.first)
        XCTAssertFalse(local.isVisible)

        panel.onActivate("local:fixture")
        XCTAssertTrue(local.isVisible, "activating a sidebar row did not bring its window forward")

        var closable: Bool?
        panel.canCloseWindow("local:fixture") { closable = $0 }
        XCTAssertEqual(closable, true)
        closable = nil
        panel.canCloseWindow("missing") { closable = $0 }
        XCTAssertEqual(closable, false)

        panel.onCloseWindow("local:fixture")
        XCTAssertFalse(local.isVisible, "closing a sidebar row left its window open")
    }

    func testPanelCallbacksOutlivingTheControllerDoNothing() async throws {
        await launch()
        await scan([window("a")])
        let sidebar = try XCTUnwrap(sidebars.first)
        let switcher = try XCTUnwrap(switchers.first)
        orphanedPanels = [sidebar, switcher]
        let store = try XCTUnwrap(self.store)
        let settings = try XCTUnwrap(self.settings)
        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        launched = false
        if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
        weak var released = controller
        controller = nil
        XCTAssertNil(released, "something kept the controller alive")

        var closable: Bool?
        sidebar.canCloseWindow("a") { closable = $0 }
        XCTAssertEqual(closable, false)
        let groups = store.groups
        sidebar.onCreateGroup("Orphan")
        sidebar.onResize(300)
        sidebar.onTogglePin("a")
        sidebar.onActivate("a")
        sidebar.onCloseWindow("a")
        sidebar.onMoveWindow("a", GroupStore.ungroupedID, nil, [:])
        sidebar.onMoveGroup(GroupStore.ungroupedID, nil)
        sidebar.onRenameGroup(GroupStore.ungroupedID, "Renamed")
        sidebar.onDeleteGroup(GroupStore.ungroupedID)
        switcher.onSelect("a")
        switcher.onActivate("a")
        XCTAssertEqual(store.groups, groups)
        XCTAssertNil(store.pinPosition(id: "a"))
        XCTAssertEqual(settings.sidebarWidth, AppSettings.defaultSidebarWidth)
    }

    func testScreenChangesRebuildPanelsAndKeepTheSwitcherOpen() async throws {
        await launch()
        await scan([window("a"), window("b")])
        let oldSidebars = sidebars.map(ObjectIdentifier.init)
        let oldPanels: [NSWindow] = sidebars + switchers
        await act(.begin(currentAppOnly: false, reverse: false))
        await act(.step(1))

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await settle()

        XCTAssertEqual(controller.sidebars.count, NSScreen.screens.count)
        XCTAssertTrue(Set(sidebars.map(ObjectIdentifier.init)).isDisjoint(with: oldSidebars))
        XCTAssertTrue(oldPanels.allSatisfy { !$0.isVisible }, "a replaced panel stayed on screen")
        XCTAssertTrue(switchers.allSatisfy(\.isVisible), "the open switcher disappeared on a display change")
        XCTAssertTrue(switchers.allSatisfy { $0.selectedRow?.titleLabel.stringValue == "b" })
        sidebars.forEach { XCTAssertEqual(rowOrder($0), ["w:a", "w:b"]) }

        await act(.cancel)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await settle()
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible }, "a closed switcher reopened on a display change")
    }

    // MARK: - Switcher

    func testCanBeginOnlyWithWindowsInScope() async throws {
        await launch()
        let canBegin = try XCTUnwrap(shortcuts.canBegin)
        XCTAssertFalse(canBegin(false))
        XCTAssertFalse(canBegin(true))

        await scan([window("a", pid: 42), window("b", pid: 7)])
        frontmostPID = nil
        XCTAssertTrue(canBegin(false))
        XCTAssertFalse(canBegin(true), "no frontmost app should match no windows")
        frontmostPID = 42
        XCTAssertTrue(canBegin(true))
        frontmostPID = 99
        XCTAssertFalse(canBegin(true))

        let other = WindowSpace(id: 2, index: 2, isCurrent: false)
        await scan([window("far", pid: 42, space: other)])
        frontmostPID = 42
        XCTAssertFalse(canBegin(false), "a window on another desktop counted")
        XCTAssertFalse(canBegin(true))
    }

    func testBeginSelectsTheNextWindowAndCommitActivatesIt() async throws {
        await launch()
        await scan([window("a"), window("b"), window("c")], focusedID: "a")
        await act(.begin(currentAppOnly: false, reverse: false))

        XCTAssertEqual(controller.currentAppOnly, false)
        XCTAssertNil(controller.currentAppPID)
        XCTAssertEqual(resultIDs, ["a", "b", "c"])
        XCTAssertEqual(controller.switchingWindowCount, 3)
        XCTAssertEqual(selectedID, "b", "the focused window was selected first")
        XCTAssertTrue(switchers.allSatisfy(\.isVisible))
        XCTAssertTrue(switchers.allSatisfy { $0.selectedRow?.titleLabel.stringValue == "b" })

        let local = localWindow("local:target", title: "Target")
        await settle()
        let target = try XCTUnwrap(resultIDs.firstIndex(of: "local:target"), "a new window did not reach the switcher")
        await act(.step(target - controller.selectedIndex))
        XCTAssertEqual(selectedID, "local:target")
        XCTAssertTrue(switchers.allSatisfy { $0.selectedRow?.titleLabel.stringValue == "Target" })

        await act(.commit)
        XCTAssertTrue(local.isVisible, "committing did not activate the selected window")
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
        XCTAssertNil(controller.currentAppOnly)
        XCTAssertEqual(controller.switchingResults.count, 0)
        XCTAssertEqual(controller.switchingWindowCount, 0)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertFalse(shortcuts.state.isSwitching)
    }

    func testBeginWithoutFocusOrReversedSelection() async throws {
        await launch()
        await scan([window("a"), window("b"), window("c")])
        await act(.begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(selectedID, "a", "an unfocused first window was skipped")
        await act(.cancel)

        await act(.begin(currentAppOnly: false, reverse: true))
        XCTAssertEqual(selectedID, "c", "switching backward did not start at the last window")
        await act(.cancel)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
    }

    func testBeginWithNoWindowsShowsNothing() async throws {
        await launch()
        await act(.begin(currentAppOnly: false, reverse: false))
        XCTAssertTrue(controller.switchingResults.isEmpty)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
        await act(.step(1))
        XCTAssertEqual(controller.selectedIndex, 0)
        await act(.commit)
        XCTAssertNil(controller.currentAppOnly)
    }

    func testStepsWrapLikeAModel() async {
        await launch()
        var generator = SplitMix(state: 0x0C0E_7E87)
        for _ in 0..<40 {
            let count = Int.random(in: 1...6, using: &generator)
            await scan((0..<count).map { window("w\($0)") })
            await act(.begin(currentAppOnly: false, reverse: Bool.random(using: &generator)))
            var expected = controller.selectedIndex
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                let amount = Int.random(in: -9...9, using: &generator)
                await act(.step(amount))
                expected = ((expected + amount) % count + count) % count
                XCTAssertEqual(controller.selectedIndex, expected, "count \(count), step \(amount)")
                XCTAssertEqual(switchers.first?.selectedRow?.titleLabel.stringValue, "w\(expected)")
            }
            await act(.cancel)
        }
    }

    func testCurrentAppSwitchingKeepsTheAppItStartedWith() async throws {
        await launch()
        let windows = [window("a1", pid: 42), window("b1", app: "Viewer", appID: "v", pid: 7), window("a2", pid: 42)]
        await scan(windows)
        frontmostPID = 42
        await act(.begin(currentAppOnly: true, reverse: false))
        XCTAssertEqual(controller.currentAppOnly, true)
        XCTAssertEqual(controller.currentAppPID, 42)
        XCTAssertEqual(resultIDs, ["a1", "a2"])

        frontmostPID = 7
        await scan(windows + [window("a3", pid: 42)])
        XCTAssertEqual(resultIDs, ["a1", "a2", "a3"], "a scan switched to the new frontmost app")
        await act(.search(""))
        XCTAssertEqual(resultIDs, ["a1", "a2", "a3"])
        XCTAssertEqual(controller.switchingWindowCount, 3)
        await act(.cancel)
        XCTAssertNil(controller.currentAppPID)
    }

    func testSearchFiltersAndRestoresTheSelection() async throws {
        await launch()
        await scan([window("a", app: "Mail", title: "Alpha"), window("b", app: "Mail", title: "Bravo"),
                    window("c", app: "Mail", title: "Charlie")])
        await act(.search("al"))
        XCTAssertTrue(controller.searchQuery.isEmpty, "a search outside the switcher was applied")

        await act(.begin(currentAppOnly: false, reverse: false))
        await act(.step(2))
        XCTAssertEqual(selectedID, "c")

        await act(.search("  r  "))
        XCTAssertEqual(controller.searchQuery, "r")
        XCTAssertEqual(Set(resultIDs), ["b", "c"])
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.switchingWindowCount, 3)
        XCTAssertTrue(switchers.allSatisfy { $0.queryLabel.stringValue == "r" })

        await act(.search("zzz"))
        XCTAssertTrue(resultIDs.isEmpty)
        XCTAssertTrue(switchers.allSatisfy { !$0.emptyState.isHidden && $0.isVisible })

        await act(.search(""))
        XCTAssertEqual(resultIDs, ["a", "b", "c"])
        XCTAssertEqual(selectedID, "c", "clearing the search lost the selection made before it")

        await act(.search("zzz"))
        await act(.commit)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
        XCTAssertTrue(controller.searchQuery.isEmpty)
    }

    func testSearchClosesTheSwitcherWhenAllWindowsAreGone() async {
        await launch()
        await scan([window("a")])
        await act(.begin(currentAppOnly: false, reverse: false))
        trust.value = false
        service.refresh()
        trust.value = true
        await act(.search("a"))
        XCTAssertNil(controller.currentAppOnly)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
    }

    func testScansRefreshTheOpenSwitcher() async throws {
        await launch()
        await scan([window("a"), window("b"), window("c")])
        await act(.begin(currentAppOnly: false, reverse: false))
        await act(.step(2))
        XCTAssertEqual(selectedID, "c")

        await scan([window("d"), window("c"), window("a")], focusedID: "d")
        XCTAssertEqual(resultIDs, ["d", "a", "c"])
        XCTAssertEqual(selectedID, "c", "a scan moved the selection off its window")
        XCTAssertEqual(controller.switchingWindowCount, 3)

        await scan([window("a"), window("d")])
        XCTAssertEqual(controller.selectedIndex, 1, "a vanished selection did not fall back to its row")

        await act(.search("delta"))
        await scan([window("a"), window("d", title: "Delta"), window("dd", title: "Delta two")])
        XCTAssertEqual(Set(resultIDs), ["d", "dd"], "a scan dropped the search query")
        XCTAssertEqual(controller.switchingWindowCount, 3)

        await scan([])
        XCTAssertNil(controller.currentAppOnly, "the switcher stayed open without windows")
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })

        await scan([window("a")])
        XCTAssertNil(controller.currentAppOnly, "a scan reopened a closed switcher")
    }

    func testPointerSelectionAndClickActivation() async throws {
        await launch()
        await scan([window("a"), window("b"), window("c")])
        let switcher = try XCTUnwrap(switchers.first)
        switcher.onSelect("b")
        XCTAssertEqual(controller.selectedIndex, 0, "hovering selected a row of a closed switcher")

        await act(.begin(currentAppOnly: false, reverse: false))
        switcher.onSelect("c")
        XCTAssertEqual(selectedID, "c")
        XCTAssertTrue(switchers.allSatisfy { $0.selectedRow?.titleLabel.stringValue == "c" })
        switcher.onSelect("c")
        switcher.onSelect("missing")
        XCTAssertEqual(selectedID, "c")

        let local = localWindow("local:click", title: "Click")
        await settle()
        switcher.onActivate("local:click")
        XCTAssertTrue(local.isVisible, "clicking a row did not activate its window")
        XCTAssertNil(controller.currentAppOnly)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
    }

    func testToggleSidebarClosesTheSwitcher() async {
        await launch()
        await scan([window("a"), window("b")])
        await act(.begin(currentAppOnly: false, reverse: false))
        await act(.toggleSidebar)
        XCTAssertNil(controller.currentAppOnly)
        XCTAssertTrue(switchers.allSatisfy { !$0.isVisible })
        XCTAssertEqual(settings.sidebarMode, .hover)
        await act(.toggleSidebar)
        XCTAssertEqual(settings.sidebarMode, .always)
    }

    func testAllDesktopsSettingWidensTheOpenSwitcher() async throws {
        // Sidebar scope already covers all desktops, so the switcher setting starts no real scan.
        defaults.set(true, forKey: "showSidebarWindowsFromAllDesktops")
        await launch()
        let other = WindowSpace(id: 2, index: 2, isCurrent: false, desktopNumber: 2)
        await scan([window("here"), window("there", space: other)])
        await act(.begin(currentAppOnly: false, reverse: false))
        XCTAssertEqual(resultIDs, ["here"])
        XCTAssertEqual(controller.switchingWindowCount, 1)

        settings.setShowWindowsFromAllDesktops(true)
        await settle()
        XCTAssertEqual(Set(resultIDs), ["here", "there"], "the open switcher ignored the desktop setting")
        XCTAssertEqual(controller.switchingWindowCount, 2)
        let headers = try XCTUnwrap(switchers.first).stack.arrangedSubviews
            .filter { $0.identifier?.rawValue == "space-header" }
        XCTAssertEqual(headers.count, 2, "windows were not grouped by desktop")
        XCTAssertTrue(try XCTUnwrap(shortcuts.canBegin)(false))
    }

    func testShortcutSettingsReachTheShortcutController() async throws {
        await launch()
        let custom = KeyboardShortcut(keyCode: 49, modifiers: .maskAlternate, keyLabel: "Space")
        XCTAssertTrue(settings.setShortcut(custom, target: .allWindows))
        settings.disableSidebarShortcut()
        await settle()
        XCTAssertEqual(shortcuts.allWindowsShortcut, custom)
        XCTAssertEqual(shortcuts.currentAppShortcut, settings.currentAppShortcut)
        XCTAssertNil(shortcuts.sidebarShortcut)
    }

    // MARK: - Menu bar and settings window

    func testMenuBarIsRebuiltOnlyForLanguageChanges() async throws {
        await launch()
        let item = try XCTUnwrap(controller.statusItem)
        let menu = try XCTUnwrap(item.menu)
        settings.setSidebarWidth(222)
        await settle()
        XCTAssertTrue(item.menu === menu, "a width change rebuilt the menu")

        settings.setLanguage(.fr)
        await settle()
        XCTAssertTrue(controller.statusItem === item, "a language change created a second status item")
        XCTAssertFalse(item.menu === menu)
        XCTAssertEqual(menuTitles().first, "Réglages…")
        XCTAssertEqual(menuTitles().last, "Quitter OtherContexts")
    }

    func testMenuOpensSettingsOnceAndQuits() async throws {
        await launch()
        let menu = try XCTUnwrap(controller.statusItem?.menu)
        menu.performActionForItem(at: 0)
        let settingsWindow = try XCTUnwrap(controller.settingsWindow)
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertTrue(service.windows.contains { $0.id == Self.settingsID })

        menu.performActionForItem(at: 0)
        XCTAssertTrue(controller.settingsWindow === settingsWindow, "Settings opened a second window")
        XCTAssertEqual(service.windows.filter { $0.id == Self.settingsID }.count, 1)

        settings.setLanguage(.fr)
        await settle()
        XCTAssertEqual(settingsWindow.title, L10n.text("OtherContexts Settings", language: .fr))

        XCTAssertEqual(terminations, 0)
        try XCTUnwrap(controller.statusItem?.menu).performActionForItem(at: 3)
        XCTAssertEqual(terminations, 1)
    }

    func testSettingsWindowDelegateTracksRegistrationAndRecording() async throws {
        await launch()
        let other = localWindow("local:other", title: "Other")
        try XCTUnwrap(controller.statusItem?.menu).performActionForItem(at: 0)
        let settingsWindow = try XCTUnwrap(controller.settingsWindow)

        shortcuts.beginRecording(target: .allWindows) { _ in true }
        controller.windowDidResignKey(notification(NSWindow.didResignKeyNotification, other))
        controller.windowDidResignKey(notification(NSWindow.didResignKeyNotification, nil))
        XCTAssertEqual(shortcuts.recordingTarget, .allWindows, "another window's focus change stopped recording")
        controller.windowDidResignKey(notification(NSWindow.didResignKeyNotification, settingsWindow))
        XCTAssertNil(shortcuts.recordingTarget)

        service.unregisterLocalWindow(id: Self.settingsID)
        controller.windowDidBecomeKey(notification(NSWindow.didBecomeKeyNotification, other))
        XCTAssertFalse(service.windows.contains { $0.id == Self.settingsID })
        controller.windowDidBecomeKey(notification(NSWindow.didBecomeKeyNotification, settingsWindow))
        XCTAssertTrue(service.windows.contains { $0.id == Self.settingsID })

        shortcuts.beginRecording(target: .currentApp) { _ in true }
        controller.windowWillClose(notification(NSWindow.willCloseNotification, other))
        XCTAssertEqual(shortcuts.recordingTarget, .currentApp)
        XCTAssertTrue(service.windows.contains { $0.id == Self.settingsID })
        settingsWindow.close()
        XCTAssertNil(shortcuts.recordingTarget, "closing Settings kept recording")
        XCTAssertFalse(service.windows.contains { $0.id == Self.settingsID })

        try XCTUnwrap(controller.statusItem?.menu).performActionForItem(at: 0)
        XCTAssertTrue(controller.settingsWindow === settingsWindow, "reopening Settings did not reuse its window")
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertTrue(service.windows.contains { $0.id == Self.settingsID })
    }
}

@MainActor
@Suite struct AppControllerAccessibilityRequestTests {
    @Test(.disabled("""
        Grant Accessibility Access… calls AXIsProcessTrustedWithOptions with the prompt option, which opens the \
        system permission dialog when the test process is not trusted for Accessibility and blocks unattended runs. \
        Remove this trait to run it on a machine where the test runner is trusted.
        """))
    func menuRequestsAccessibility() async throws {
        let suite = "OpenContexts.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = NSApplication.shared
        var trusted = false
        let service = WindowService(isTrusted: { trusted })
        let controller = AppController(
            windowService: service, groupStore: GroupStore(fileURL: directory.appendingPathComponent("groups.json")),
            shortcuts: ShortcutController(), settings: AppSettings(defaults: defaults),
            frontmostProcessID: { nil }, terminate: {}
        )
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            controller.settingsWindow?.close()
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        service.stop()
        #expect(!service.hasAccessibility)

        trusted = true
        try #require(controller.statusItem?.menu).performActionForItem(at: 1)
        #expect(service.hasAccessibility, "requesting access did not recheck the trust state")
        await withCheckedContinuation { continuation in service.scanQueue.async { continuation.resume() } }
    }
}
