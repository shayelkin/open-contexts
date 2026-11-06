import AppKit
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

/// A drag delivered to the sidebar's drop target, standing in for the one AppKit builds during a real drag.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
final class PanelInteractionTests: XCTestCase {
    private static let windowType = NSPasteboard.PasteboardType("com.shayelkin.opencontexts.window")
    private static let groupType = NSPasteboard.PasteboardType("com.shayelkin.opencontexts.group")
    private static let firstGroupID = "first"
    private static let secondGroupID = "second"
    private static let groups = [
        WindowGroup(id: GroupStore.ungroupedID, name: "Ungrouped"),
        WindowGroup(id: firstGroupID, name: "First"),
        WindowGroup(id: secondGroupID, name: "Second")
    ]

    private var screen: NSScreen!
    private var sidebar: SidebarPanel!
    private var pasteboard: NSPasteboard!
    private var hosts: [NSWindow] = []
    private var activated: [String] = []
    private var pinned: [String] = []
    private var windowMoves: [String] = []
    private var groupMoves: [String] = []
    private var created: [String] = []
    private var renamed: [String] = []

    private func window(_ id: String, title: String? = nil, pid: pid_t = getpid()) -> WindowInfo {
        WindowInfo(id: id, appID: "test", appName: "Test", title: title ?? id, processID: pid)
    }

    private var windowsByGroup: [String: [WindowInfo]] {
        [
            GroupStore.ungroupedID: [window("u1"), window("u2")],
            Self.firstGroupID: [window("f1"), window("f2")],
            Self.secondGroupID: [window("s1"), window("s2")]
        ]
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        sidebar = SidebarPanel(
            screen: screen,
            onActivate: { [unowned self] in self.activated.append($0) },
            canCloseWindow: { $1(true) },
            onCloseWindow: { _ in },
            windowPinPosition: { _ in nil },
            onTogglePin: { [unowned self] in self.pinned.append($0) },
            onMoveWindow: { [unowned self] id, groupID, beforeID, _ in
                self.windowMoves.append("\(id)>\(groupID)<\(beforeID ?? "end")")
            },
            onMoveGroup: { [unowned self] id, beforeID in self.groupMoves.append("\(id)<\(beforeID ?? "end")") },
            onCreateGroup: { [unowned self] in self.created.append($0) },
            onRenameGroup: { [unowned self] in self.renamed.append("\($0)=\($1)") },
            onDeleteGroup: { _ in },
            onResize: { _ in }
        )
        sidebar.smokeStopHoverPolling()
        sidebar.smokeSetAnimatesVisibility(false)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenContexts.tests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        sidebar.close()
        sidebar = nil
        hosts.forEach { $0.close() }
        hosts = []
        pasteboard.releaseGlobally()
        SidebarTooltipPanel.shared.orderOut(nil)
    }

    private func showSidebar(position: SidebarPosition = .right) {
        sidebar.update(groups: Self.groups, windowsByGroup: windowsByGroup, alwaysVisible: true, fullscreen: false,
                       position: position, language: .en)
        sidebar.contentView?.layoutSubtreeIfNeeded()
    }

    private func row(_ key: String) throws -> SidebarItemView {
        try XCTUnwrap(sidebar.sidebarRows.first {
            switch $0.style {
            case .group(let id): "g:\(id)" == key
            case .window(let id, _): "w:\(id)" == key
            }
        }, key)
    }

    /// A drag location, in window coordinates, at `fraction` of the row's length along the sidebar.
    private func location(over key: String, at fraction: CGFloat) throws -> NSPoint {
        let frame = try row(key).frame
        let point = sidebar.position == .bottom
            ? NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
            : NSPoint(x: frame.midX, y: frame.minY + frame.height * fraction)
        return sidebar.stack.convert(point, to: nil)
    }

    private func drag(_ type: NSPasteboard.PasteboardType, _ id: String, at location: NSPoint) -> FakeDraggingInfo {
        pasteboard.clearContents()
        pasteboard.setString(id, forType: type)
        return FakeDraggingInfo(pasteboard: pasteboard, location: location)
    }

    private func host(_ view: NSView, size: NSSize = NSSize(width: 300, height: 40)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        hosts.append(window)
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1))
    }

    private func emptyCoder() throws -> NSCoder {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.finishEncoding()
        return try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields(in:))
    }

    /// Answers the next modal prompt from inside its modal run loop, optionally typing into its text field,
    /// and returns the texts the prompt showed.
    private func answerNextModal(typing text: String? = nil, with response: NSApplication.ModalResponse,
                                 shown: @escaping ([String]) -> Void) -> Timer {
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, let content = window.contentView else { return }
                let fields = Self.textFields(in: content)
                shown(fields.map(\.stringValue))
                if let text, let field = fields.first(where: \.isEditable) { field.stringValue = text }
                timer.invalidate()
                NSApp.stopModal(withCode: response)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }

    // MARK: - Panels

    func testPanelsNeverBecomeKeyOrMain() throws {
        let switcher = SwitcherPanel(screen: screen, onActivate: { _ in }, onSelect: { _ in })
        defer { switcher.close() }
        let panels: [NSWindow] = [sidebar, switcher, SidebarTooltipPanel.shared]
        for panel in panels {
            XCTAssertFalse(panel.canBecomeKey, "\(type(of: panel))")
            XCTAssertFalse(panel.canBecomeMain, "\(type(of: panel))")
        }
    }

    func testTitleChangesAlongsidePresentationChangesKeepRowsAndRelayout() throws {
        for position in [SidebarPosition.right, .bottom] {
            showSidebar(position: position)
            let identity = ObjectIdentifier(try row("w:u1"))
            XCTAssertEqual(sidebar.revealTarget, 1)
            var renamedWindows = windowsByGroup
            renamedWindows[GroupStore.ungroupedID] = [window("u1", title: "Renamed"), window("u2")]
            sidebar.update(groups: Self.groups, windowsByGroup: renamedWindows, alwaysVisible: false,
                           fullscreen: false, position: position, language: .en)
            XCTAssertEqual(ObjectIdentifier(try row("w:u1")), identity, "a title change rebuilt the rows")
            XCTAssertEqual(try row("w:u1").titleLabel.stringValue, "Renamed")
            XCTAssertEqual(sidebar.revealTarget, 0, "the visibility change was not laid out")
        }
    }

    // MARK: - Drag and drop

    func testDroppingAWindowPreviewsRestoresAndCommits() throws {
        showSidebar()
        let original = sidebar.smokeRowOrder
        let stack = sidebar.stack
        let info = drag(Self.windowType, "u1", at: try location(over: "w:s1", at: 0.25))

        XCTAssertEqual(stack.draggingEntered(info), .move)
        XCTAssertTrue(sidebar.smokeIsDragging)
        XCTAssertEqual(sidebar.previewDrop, .window(id: "u1", groupID: Self.secondGroupID, beforeWindowID: "s1"))
        XCTAssertNotEqual(sidebar.smokeRowOrder, original, "the drop was not previewed")
        XCTAssertEqual(stack.draggingUpdated(info), .move)
        XCTAssertTrue(windowMoves.isEmpty, "a preview moved the window")

        stack.draggingExited(info)
        XCTAssertEqual(sidebar.smokeRowOrder, original, "leaving the sidebar kept the preview")
        XCTAssertNil(sidebar.previewDrop)
        XCTAssertFalse(sidebar.smokeIsDragging)
        stack.draggingExited(nil)
        XCTAssertEqual(sidebar.smokeRowOrder, original)

        XCTAssertEqual(stack.draggingEntered(info), .move)
        XCTAssertTrue(stack.performDragOperation(info))
        XCTAssertEqual(windowMoves, ["u1>\(Self.secondGroupID)<s1"])
        stack.concludeDragOperation(info)
        XCTAssertFalse(sidebar.smokeIsDragging)
        XCTAssertEqual(sidebar.smokeRowOrder, original, "the sidebar kept a preview the store did not confirm")
    }

    func testWindowDropsBelowTheLastRowGoToTheEndOfTheLastGroup() throws {
        showSidebar()
        let below = sidebar.stack.convert(NSPoint(x: 20, y: sidebar.stack.bounds.maxY + 100), to: nil)
        let info = drag(Self.windowType, "u1", at: below)
        XCTAssertTrue(sidebar.stack.performDragOperation(info))
        XCTAssertEqual(windowMoves, ["u1>\(Self.secondGroupID)<end"])
    }

    func testDroppingAWindowOnItselfOnlyKeepsAnExistingPreview() throws {
        showSidebar()
        let stack = sidebar.stack
        let onItself = drag(Self.windowType, "f1", at: try location(over: "w:f1", at: 0.25))
        XCTAssertEqual(stack.draggingEntered(onItself), [], "a window was dropped before itself")
        XCTAssertFalse(stack.performDragOperation(onItself))

        let elsewhere = drag(Self.windowType, "f1", at: try location(over: "w:s2", at: 0.25))
        XCTAssertEqual(stack.draggingUpdated(elsewhere), .move)
        let preview = try XCTUnwrap(sidebar.previewDrop)
        onItself.draggingLocation = try location(over: "w:f1", at: 0.25)
        XCTAssertEqual(stack.draggingUpdated(onItself), .move, "hovering the dragged row lost the preview")
        XCTAssertEqual(sidebar.previewDrop, preview)
        stack.concludeDragOperation(onItself)
    }

    func testDroppingGroups() throws {
        showSidebar()
        let stack = sidebar.stack
        let beforeFirst = try location(over: "g:\(Self.firstGroupID)", at: 0.25)

        let second = drag(Self.groupType, Self.secondGroupID, at: beforeFirst)
        XCTAssertEqual(stack.draggingEntered(second), .move)
        XCTAssertEqual(sidebar.previewDrop, .group(id: Self.secondGroupID, beforeGroupID: Self.firstGroupID))
        XCTAssertTrue(stack.performDragOperation(second))
        XCTAssertEqual(groupMoves, ["\(Self.secondGroupID)<\(Self.firstGroupID)"])
        stack.concludeDragOperation(second)

        let ungrouped = drag(Self.groupType, GroupStore.ungroupedID, at: beforeFirst)
        XCTAssertEqual(stack.draggingEntered(ungrouped), [], "Ungrouped was dragged")
        XCTAssertFalse(stack.performDragOperation(ungrouped))
        stack.concludeDragOperation(ungrouped)

        let onItself = drag(Self.groupType, Self.firstGroupID, at: beforeFirst)
        XCTAssertEqual(stack.draggingEntered(onItself), [], "a group was dropped before itself")
        onItself.draggingLocation = try location(over: "g:\(Self.secondGroupID)", at: 0.25)
        XCTAssertEqual(stack.draggingUpdated(onItself), .move)
        onItself.draggingLocation = beforeFirst
        XCTAssertEqual(stack.draggingUpdated(onItself), .move, "hovering the dragged group lost the preview")
        XCTAssertEqual(sidebar.previewDrop, .group(id: Self.firstGroupID, beforeGroupID: Self.secondGroupID))

        let below = sidebar.stack.convert(NSPoint(x: 20, y: sidebar.stack.bounds.maxY + 100), to: nil)
        onItself.draggingLocation = below
        XCTAssertEqual(stack.draggingUpdated(onItself), .move)
        XCTAssertEqual(sidebar.previewDrop, .group(id: Self.firstGroupID, beforeGroupID: nil))
        stack.concludeDragOperation(onItself)
    }

    func testDragsWithoutSidebarContentAreRejected() throws {
        showSidebar()
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        let foreign = FakeDraggingInfo(pasteboard: pasteboard, location: try location(over: "w:f1", at: 0.5))
        XCTAssertEqual(sidebar.stack.draggingEntered(foreign), [])
        XCTAssertFalse(sidebar.stack.performDragOperation(foreign))
        sidebar.stack.concludeDragOperation(foreign)
        XCTAssertTrue(windowMoves.isEmpty && groupMoves.isEmpty)

        let detached = FlippedStackView()
        XCTAssertEqual(detached.draggingEntered(foreign), [])
        XCTAssertEqual(detached.draggingUpdated(foreign), [])
        XCTAssertFalse(detached.performDragOperation(foreign))
    }

    func testDecodedStackStillAcceptsSidebarDrags() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: FlippedStackView(), requiringSecureCoding: false)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        let decoded = try XCTUnwrap(unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? FlippedStackView)
        XCTAssertEqual(Set(decoded.registeredDraggedTypes), [Self.windowType, Self.groupType])
        XCTAssertTrue(decoded.isFlipped)
    }

    // MARK: - Menus and prompts

    func testWindowMenuPinsAndActivatesOnlyRenderedWindows() throws {
        showSidebar()
        let menu = try XCTUnwrap(try row("w:f1").menu)
        sidebar.menuNeedsUpdate(menu)
        let pin = try XCTUnwrap(menu.items.first { $0.title == "Pin" })
        let siblings = menu.items.compactMap { item -> NSMenuItem? in
            guard let id = item.representedObject as? String, item.title != "Pin", item.title != "Close Window"
            else { return nil }
            return id == "s2" ? item : nil
        }
        let sibling = try XCTUnwrap(siblings.first, "the menu did not list the app's other windows")
        menu.performActionForItem(at: menu.index(of: pin))
        menu.performActionForItem(at: menu.index(of: sibling))
        XCTAssertEqual(pinned, ["f1"])
        XCTAssertEqual(activated, ["s2"])

        sidebar.update(groups: Self.groups, windowsByGroup: [GroupStore.ungroupedID: [window("u1")]],
                       alwaysVisible: true, fullscreen: false, language: .en)
        menu.performActionForItem(at: menu.index(of: pin))
        menu.performActionForItem(at: menu.index(of: sibling))
        XCTAssertEqual(pinned, ["f1"], "a stale menu pinned a window the sidebar no longer shows")
        XCTAssertEqual(activated, ["s2"], "a stale menu activated a window the sidebar no longer shows")
    }

    func testHideAppIgnoresItemsWithoutARunningApp() throws {
        let dock = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        sidebar.update(groups: Self.groups, windowsByGroup: [GroupStore.ungroupedID: [
            window("dock", pid: dock.processIdentifier)
        ]], alwaysVisible: true, fullscreen: false, language: .en)
        let menu = try XCTUnwrap(try row("w:dock").menu)
        sidebar.menuNeedsUpdate(menu)
        let hide = try XCTUnwrap(menu.items.first { $0.title == "Hide App" })
        XCTAssertEqual(hide.representedObject as? Int32, dock.processIdentifier)
        for target in [Optional<Any>.none, "not a pid", Int32.max] as [Any?] {
            let item = NSMenuItem(title: hide.title, action: hide.action, keyEquivalent: "")
            item.target = hide.target
            item.representedObject = target
            _ = (item.target as AnyObject).perform(item.action, with: item)
        }
        XCTAssertFalse(dock.isHidden)
    }

    func testCreatingAndRenamingGroupsPromptForANameAndRespectCancel() throws {
        NSApp.setActivationPolicy(.accessory)
        showSidebar()
        let create = try XCTUnwrap(sidebar.stack.arrangedSubviews.compactMap { $0 as? CallbackButton }.first)
        XCTAssertEqual(create.title, "＋ New Group")

        var shown: [String] = []
        var timer = answerNextModal(typing: "Projects", with: .alertFirstButtonReturn) { shown = $0 }
        create.performClick(nil)
        timer.invalidate()
        XCTAssertTrue(shown.contains("New Group"), "the prompt was not titled: \(shown)")
        XCTAssertEqual(created, ["Projects"])

        timer = answerNextModal(typing: "Ignored", with: .alertSecondButtonReturn) { _ in }
        create.performClick(nil)
        timer.invalidate()
        XCTAssertEqual(created, ["Projects"], "a cancelled prompt created a group")

        let menu = try XCTUnwrap(try row("g:\(Self.firstGroupID)").menu)
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename" })
        timer = answerNextModal(typing: "Renamed", with: .alertFirstButtonReturn) { shown = $0 }
        menu.performActionForItem(at: menu.index(of: rename))
        timer.invalidate()
        XCTAssertTrue(shown.contains("First"), "the rename prompt did not start from the current name: \(shown)")
        XCTAssertEqual(renamed, ["\(Self.firstGroupID)=Renamed"])

        let detached = NSMenuItem(title: rename.title, action: rename.action, keyEquivalent: "")
        detached.target = rename.target
        _ = (detached.target as AnyObject).perform(detached.action, with: detached)
        XCTAssertEqual(renamed, ["\(Self.firstGroupID)=Renamed"])
    }

    func testDeletingAGroupWithoutAConfirmationHandlerAsksWithAnAlert() throws {
        NSApp.setActivationPolicy(.accessory)
        var deleted: [String] = []
        sidebar.close()
        sidebar = SidebarPanel(screen: screen, onActivate: { _ in }, canCloseWindow: { $1(true) },
                               onCloseWindow: { _ in }, windowPinPosition: { _ in nil }, onTogglePin: { _ in },
                               onMoveWindow: { _, _, _, _ in }, onMoveGroup: { _, _ in }, onCreateGroup: { _ in },
                               onRenameGroup: { _, _ in }, onDeleteGroup: { deleted.append($0) }, onResize: { _ in })
        sidebar.smokeStopHoverPolling()
        showSidebar()
        XCTAssertNil(sidebar.confirmDestructiveAction)
        let menu = try XCTUnwrap(try row("g:\(Self.firstGroupID)").menu)
        let delete = try XCTUnwrap(menu.items.first { $0.title == "Delete Group" })

        var shown: [String] = []
        var timer = answerNextModal(with: .alertSecondButtonReturn) { shown = $0 }
        menu.performActionForItem(at: menu.index(of: delete))
        timer.invalidate()
        XCTAssertTrue(shown.contains("Delete the group “First”?"), "\(shown)")
        XCTAssertTrue(shown.contains("Its windows move to Ungrouped."), "\(shown)")
        XCTAssertEqual(deleted, [], "cancelling the alert deleted the group")

        timer = answerNextModal(with: .alertFirstButtonReturn) { _ in }
        menu.performActionForItem(at: menu.index(of: delete))
        timer.invalidate()
        XCTAssertEqual(deleted, [Self.firstGroupID])
    }

    // MARK: - Pointer input

    func testPointerTrackerReactsToLocalMouseMovesUntilStopped() throws {
        var changes = 0
        let tracker = PointerTracker { changes += 1 }
        let moved = try mouseEvent(.mouseMoved, at: .zero, in: nil)
        NSApp.sendEvent(moved)
        XCTAssertEqual(changes, 1)
        tracker.stop()
        NSApp.sendEvent(moved)
        XCTAssertEqual(changes, 1, "a stopped tracker kept reacting")

        let polling = SidebarPanel(screen: screen, onActivate: { _ in }, canCloseWindow: { $1(true) },
                                   onCloseWindow: { _ in }, windowPinPosition: { _ in nil }, onTogglePin: { _ in },
                                   onMoveWindow: { _, _, _, _ in }, onMoveGroup: { _, _ in }, onCreateGroup: { _ in },
                                   onRenameGroup: { _, _ in }, onDeleteGroup: { _ in }, onResize: { _ in })
        defer { polling.close() }
        polling.update(groups: Self.groups, windowsByGroup: windowsByGroup, alwaysVisible: false, fullscreen: false,
                       enabled: false)
        XCTAssertNil(polling.pointerTracker, "a disabled sidebar kept polling")
        polling.update(groups: Self.groups, windowsByGroup: windowsByGroup, alwaysVisible: true, fullscreen: false)
        XCTAssertNotNil(polling.pointerTracker)
        NSApp.sendEvent(moved)
        XCTAssertEqual(polling.revealTarget, 1, "pointer polling collapsed an always-visible sidebar")
    }

    func testSidebarItemClicksHoverAndTracking() throws {
        var clicks = 0
        var draggingChanges: [Bool] = []
        let item = SidebarItemView(title: "Item", icon: NSImage(size: NSSize(width: 16, height: 16)),
                                   style: .window(id: "w", groupID: GroupStore.ungroupedID),
                                   onClick: { clicks += 1 }, onDraggingChanged: { draggingChanges.append($0) })
        let window = host(item)
        let center = NSPoint(x: 150, y: 20)

        item.mouseDown(with: try mouseEvent(.leftMouseDown, at: center, in: window))
        item.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 151, y: 21), in: window))
        item.mouseUp(with: try mouseEvent(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(clicks, 1, "a click with a tiny jitter was not a click")
        XCTAssertEqual(draggingChanges, [])
        item.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 190, y: 20), in: window))
        XCTAssertEqual(draggingChanges, [], "a drag started without a mouse down")

        item.mouseEntered(with: try mouseEvent(.mouseMoved, at: center, in: window))
        XCTAssertEqual(item.layer?.backgroundColor, appAccentColor.cgColor)
        XCTAssertEqual(item.titleLabel.textColor, .white)
        item.mouseExited(with: try mouseEvent(.mouseMoved, at: center, in: window))
        XCTAssertEqual(item.layer?.backgroundColor, NSColor.clear.cgColor)

        item.updateTrackingAreas()
        item.updateTrackingAreas()
        XCTAssertEqual(item.trackingAreas.count, 1, "tracking areas piled up")

        let icon = NSImage(size: NSSize(width: 20, height: 20))
        item.setIcon(icon)
        XCTAssertTrue(item.iconView?.image === icon)
        XCTAssertNil(SidebarItemView(coder: try emptyCoder()))
    }

    func testDraggingSidebarItemsReportsTheSessionAndSkipsUngrouped() throws {
        var draggingChanges: [Bool] = []
        let ungrouped = SidebarItemView(title: "Ungrouped", style: .group(id: GroupStore.ungroupedID), onClick: nil,
                                        onDraggingChanged: { draggingChanges.append($0) })
        let ungroupedWindow = host(ungrouped)
        ungrouped.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 10), in: ungroupedWindow))
        ungrouped.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 10), in: ungroupedWindow))
        XCTAssertEqual(draggingChanges, [], "Ungrouped started a drag")

        // A drag that passes these checks starts a real AppKit drag session, which blocks the test run.
        let item = SidebarItemView(title: "Item", style: .window(id: "w", groupID: "g"), onClick: nil,
                                   onDraggingChanged: { draggingChanges.append($0) })
        let session = NSDraggingSession()
        XCTAssertEqual(item.draggingSession(session, sourceOperationMaskFor: .withinApplication), .move)
        XCTAssertEqual(item.draggingSession(session, sourceOperationMaskFor: .outsideApplication), .move)
        item.draggingSession(session, endedAt: .zero, operation: .move)
        XCTAssertEqual(draggingChanges, [false], "the end of a drag session was not reported")
    }

    func testTooltipAppearsAfterTheSystemDelay() async throws {
        let key = SidebarTooltipLayout.initialDelayDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(1, forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        sidebar.update(groups: Self.groups, windowsByGroup: [GroupStore.ungroupedID: [
            window("long", title: String(repeating: "A long title ", count: 30))
        ]], alwaysVisible: true, fullscreen: false)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        let item = try row("w:long")
        XCTAssertTrue(item.needsTooltip)
        item.smokeHover(true)
        XCTAssertNotNil(item.tooltipTimer)
        for _ in 0..<40 where SidebarTooltipPanel.shared.owner !== item {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(SidebarTooltipPanel.shared.owner === item, "the tooltip did not appear after the delay")
        XCTAssertTrue(SidebarTooltipPanel.shared.isVisible)
        item.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero, in: sidebar))
        XCTAssertNil(SidebarTooltipPanel.shared.owner, "pressing the item kept its tooltip")
    }

    func testResizeHandleForwardsMouseInput() throws {
        var events: [String] = []
        let handle = SidebarResizeHandle()
        handle.onBegin = { events.append("begin \($0)") }
        handle.onDrag = { events.append("drag \($0)") }
        handle.onEnd = { events.append("end") }
        let window = host(handle, size: NSSize(width: 8, height: 100))
        let x = NSEvent.mouseLocation.x

        handle.mouseEntered(with: try mouseEvent(.mouseMoved, at: .zero, in: window))
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        handle.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero, in: window))
        handle.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: .zero, in: window))
        handle.mouseExited(with: try mouseEvent(.mouseMoved, at: .zero, in: window))
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight, "leaving mid-resize reset the cursor")
        handle.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero, in: window))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        XCTAssertEqual(events, ["begin \(x)", "drag \(x)", "end"])

        handle.mouseEntered(with: try mouseEvent(.mouseMoved, at: .zero, in: window))
        handle.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero, in: window))
        handle.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero, in: window))
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight, "a resize ending over the handle reset the cursor")

        handle.updateTrackingAreas()
        handle.updateTrackingAreas()
        XCTAssertEqual(handle.trackingAreas.count, 1)
        handle.resetCursorRects()
    }

    func testSwitcherRowsReportPointerMovesInsideAndInvokeTheirAction() throws {
        var pointers: [NSPoint] = []
        var invoked = 0
        let match = try XCTUnwrap(WindowSearch.filter([window("w")], query: "").first)
        let row = SwitcherRow(match: match,
                              selected: false, onPointerMove: { pointers.append($0) }, action: { invoked += 1 })
        let inside = NSPoint(x: 10, y: 10)
        row.mouseMoved(with: try mouseEvent(.mouseMoved, at: inside, in: nil))
        XCTAssertEqual(pointers, [], "a row outside a window reported a pointer")

        let window = host(row)
        row.mouseMoved(with: try mouseEvent(.mouseMoved, at: inside, in: window))
        row.mouseEntered(with: try mouseEvent(.mouseMoved, at: inside, in: window))
        row.mouseMoved(with: try mouseEvent(.mouseMoved, at: NSPoint(x: 10, y: 500), in: window))
        let screenPoint = window.convertPoint(toScreen: inside)
        XCTAssertEqual(pointers, [screenPoint, screenPoint])

        row.updateTrackingAreas()
        row.updateTrackingAreas()
        XCTAssertEqual(row.trackingAreas.count, 1)

        row.performClick(nil)
        XCTAssertEqual(invoked, 1)
        XCTAssertNil(SwitcherRow(coder: try emptyCoder()))
        XCTAssertNil(CallbackButton(coder: try emptyCoder()))
    }
}
