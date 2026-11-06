import AppKit
import ApplicationServices
import Combine
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

@MainActor
final class WindowServiceTests: XCTestCase {
    private final class RefusingCloseDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func tracked(_ id: String, title: String? = nil, documentURL: String? = nil) -> WindowService.TrackedWindow {
        WindowService.TrackedWindow(id: id, element: AXUIElementCreateApplication(0),
                                    info: WindowInfo(id: id, appID: "test", appName: "Test", title: title ?? id,
                                                     documentURL: documentURL, processID: 0))
    }

    private func scanResult(_ windows: [WindowService.TrackedWindow], focusedID: String? = nil) -> WindowService.ScanResult {
        WindowService.ScanResult(windows: windows, focusedID: focusedID, fullscreenScreenIDs: [],
                                 activeAppIDs: [], badgeReads: nil)
    }

    func testLocalWindowRegistrationIsDeduplicatedAndSurvivesScans() {
        let service = WindowService(isTrusted: { true })
        let id = "local:test"
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        service.registerLocalWindow(window, id: id)
        XCTAssertEqual(service.windows.map(\.id), [id])
        service.registerLocalWindow(window, id: id)
        XCTAssertEqual(service.windows.filter { $0.id == id }.count, 1)
        service.unregisterLocalWindow(id: id)
        service.apply(scanResult([]))
        XCTAssertFalse(service.windows.contains { $0.id == id })
        service.registerLocalWindow(window, id: id)
        XCTAssertEqual(service.windows.filter { $0.id == id }.count, 1)
    }

    func testClosingTargetsOnlyClosableLocalWindow() {
        let service = WindowService()
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }
        defer { windows.forEach { $0.close() } }
        for (index, window) in windows.enumerated() {
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            service.registerLocalWindow(window, id: "close-\(index)")
        }
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        XCTAssertTrue(service.canClose("close-0"))
        XCTAssertFalse(service.canClose("missing"))
        service.close("missing")
        service.close("close-0")
        XCTAssertFalse(windows[0].isVisible)
        XCTAssertTrue(windows[1].isVisible)

        windows[1].standardWindowButton(.closeButton)?.isEnabled = false
        service.close("close-1")
        XCTAssertFalse(service.canClose("close-1"))
        XCTAssertTrue(windows[1].isVisible)

        windows[1].standardWindowButton(.closeButton)?.isEnabled = true
        let delegate = RefusingCloseDelegate()
        windows[1].delegate = delegate
        withExtendedLifetime(delegate) {
            service.close("close-1")
            XCTAssertTrue(windows[1].isVisible)
        }
    }

    func testScansKeepFirstSeenOrderWithFocusedWindowFirst() {
        let service = WindowService(isTrusted: { true })
        var samples = ["A", "B", "C", "D"].map { tracked($0) }
        for (step, (ids, focus, expected)) in [
            ([0, 1, 2], "A", ["A", "B", "C"]),
            ([1, 0, 2], "B", ["B", "A", "C"]),
            ([0, 1, 2], "A", ["A", "B", "C"]),
            ([3, 2, 1, 0], "A", ["A", "B", "C", "D"]),
            ([3, 2, 0], "C", ["C", "A", "D"])
        ].enumerated() {
            if step == 1 { samples[1] = tracked("B", title: "Updated B", documentURL: "file:///B") }
            service.apply(scanResult(ids.map { samples[$0] }, focusedID: focus))
            XCTAssertEqual(service.tracked.map(\.id), expected, "step \(step)")
            XCTAssertEqual(service.windows.map(\.id), expected, "step \(step)")
            XCTAssertEqual(service.focusedWindowID, focus, "step \(step)")
            XCTAssertEqual(service.windows, expected.compactMap { id in samples.first { $0.id == id }?.info }, "step \(step)")
        }
    }

    func testUntrustedScanClearsExternalWindows() {
        var trusted = true
        let service = WindowService(isTrusted: { trusted })
        service.apply(scanResult([tracked("A")], focusedID: "A"))
        XCTAssertEqual(service.windows.map(\.id), ["A"])
        XCTAssertTrue(service.hasAccessibility)
        trusted = false
        service.apply(scanResult([tracked("B")], focusedID: "B"))
        XCTAssertTrue(service.windows.isEmpty)
        XCTAssertTrue(service.tracked.isEmpty)
        XCTAssertNil(service.focusedWindowID)
        XCTAssertFalse(service.hasAccessibility)
    }

    func testFocusChangesArePublished() {
        let service = WindowService(isTrusted: { true })
        var updates: [String?] = []
        let subscription = service.$focusedWindowID.sink { updates.append($0) }
        defer { subscription.cancel() }
        for focus in ["A", nil, "A"] {
            service.apply(scanResult([tracked("A")], focusedID: focus))
            XCTAssertEqual(service.focusedWindowID, focus)
            XCTAssertEqual(service.windows.map(\.id), ["A"])
        }
        XCTAssertEqual(updates, [nil, "A", nil, "A"])
    }

    func testNewWindowInheritsIDOfVanishedNativeTab() {
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        func tab(_ id: String, element: pid_t, processID: pid_t = 1, frame: CGRect?) -> WindowService.TrackedWindow {
            WindowService.TrackedWindow(id: id, element: AXUIElementCreateApplication(element),
                                        info: WindowInfo(id: id, appID: "check", appName: "Check", title: id,
                                                         processID: processID),
                                        frame: frame)
        }
        func resolve(_ frame: CGRect?, windowID: CGWindowID? = 7, listed: [WindowService.TrackedWindow] = [],
                     previous: [WindowService.TrackedWindow], usedIDs: Set<String> = [],
                     pending: Set<CGWindowID> = []) -> (id: String?, deferred: Set<CGWindowID>) {
            var deferred: Set<CGWindowID> = []
            let id = WindowService.newWindowID(frame: frame, windowID: windowID, processID: 1,
                                               listed: listed.map(\.element), previous: previous, usedIDs: usedIDs,
                                               pendingTabs: pending, deferredTabs: &deferred)
            return (id, deferred)
        }
        func assertFresh(_ result: (id: String?, deferred: Set<CGWindowID>), _ message: String,
                         line: UInt = #line) {
            XCTAssertTrue(result.deferred.isEmpty, message, line: line)
            XCTAssertNotNil(result.id.flatMap(UUID.init(uuidString:)), message, line: line)
        }
        let old = tab("old", element: 9001, frame: frame)
        let twin = tab("twin", element: 9002, frame: frame)
        let moved = tab("moved", element: 9003, frame: frame.offsetBy(dx: 1, dy: 0))
        let resized = tab("resized", element: 9004, frame: frame.insetBy(dx: 0, dy: 1))
        let otherApp = tab("other-app", element: 9005, processID: 2, frame: frame)
        let unknown = tab("unknown", element: 9006, frame: nil)
        let empty = CGRect(x: 5, y: 5, width: 0, height: 100)

        let inherited = resolve(frame, previous: [moved, old, unknown, otherApp])
        XCTAssertEqual(inherited.id, "old")
        XCTAssertTrue(inherited.deferred.isEmpty)
        let incoming = resolve(frame, listed: [old], previous: [old])
        XCTAssertNil(incoming.id)
        XCTAssertEqual(incoming.deferred, [7])
        let ambiguousIncoming = resolve(frame, listed: [twin],
                                        previous: [old, twin, tab("third", element: 9007, frame: frame)])
        XCTAssertNil(ambiguousIncoming.id)
        XCTAssertEqual(ambiguousIncoming.deferred, [7])

        assertFresh(resolve(frame, listed: [old], previous: [old], pending: [7]), "already deferred once")
        assertFresh(resolve(frame, windowID: nil, listed: [old], previous: [old]), "no window ID")
        assertFresh(resolve(frame, previous: [old], usedIDs: ["old"]), "sibling ID already used")
        assertFresh(resolve(frame, previous: [old, twin]), "two vanished siblings")
        assertFresh(resolve(frame, previous: [moved, resized, otherApp, unknown]), "no sibling with the same frame")
        assertFresh(resolve(frame, previous: []), "no previous windows")
        assertFresh(resolve(nil, listed: [unknown], previous: [unknown]), "unknown frame")
        let zero = tab("zero", element: 9008, frame: .zero)
        assertFresh(resolve(.zero, listed: [zero], previous: [zero]), "zero frame")
        assertFresh(resolve(empty, previous: [tab("empty", element: 9009, frame: empty)]), "empty frame")
    }

    func testDiscoveryIndexStaysInRangeForEveryPass() {
        var random = SystemRandomNumberGenerator()
        let edges = [Int.min, Int.min + 1, -1, 0, 1, Int.max - 1, Int.max]
        for pass in edges + (0..<5_000).map({ _ in Int.random(in: Int.min...Int.max, using: &random) }) {
            for count in 1...7 {
                XCTAssertTrue((0..<count).contains(WindowService.discoveryIndex(pass: pass, count: count)),
                              "pass \(pass), count \(count)")
            }
        }
        XCTAssertEqual((0..<6).map { WindowService.discoveryIndex(pass: $0, count: 3) }, [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(WindowService.discoveryIndex(pass: Int.max &+ 1, count: 3),
                       WindowService.discoveryIndex(pass: Int.min, count: 3))
    }

    func testPrivateAPIResultsAreTypeChecked() {
        XCTAssertNil(WindowSpaces.array(nil))
        XCTAssertNil(WindowSpaces.array(Unmanaged.passRetained("text" as CFString)))
        XCTAssertNil(WindowSpaces.array(Unmanaged.passRetained(AXUIElementCreateApplication(getpid()))))
        XCTAssertEqual(WindowSpaces.array(Unmanaged.passRetained([1, 2] as CFArray)) as? [Int], [1, 2])
        XCTAssertNil(WindowSpaces.uiElement("text" as CFString))
        XCTAssertNil(WindowSpaces.uiElement([] as CFArray))
        XCTAssertNotNil(WindowSpaces.uiElement(AXUIElementCreateApplication(getpid())))
    }

    func testDuplicateWindowIDsAreDeduplicatedInsteadOfCrashing() {
        let service = WindowService(isTrusted: { true })
        service.apply(scanResult([tracked("A", title: "first"), tracked("A", title: "second"), tracked("B")]))
        XCTAssertEqual(service.windows.map(\.id), ["A", "B"])
        XCTAssertEqual(service.windows.first?.title, "first")

        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Local"
        service.registerLocalWindow(window, id: "B")
        XCTAssertEqual(service.windows.map(\.id), ["A", "B"])
        XCTAssertEqual(service.windows.last?.title, "B")
        service.unregisterLocalWindow(id: "B")
    }

    func testCoreFoundationCastsCheckTheRuntimeType() throws {
        var point = CGPoint(x: 1, y: 2)
        let element = AXUIElementCreateApplication(getpid())
        let value = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let samples: [(name: String, value: CFTypeRef, isElement: Bool, isValue: Bool, isElements: Bool)] = [
            ("string", "text" as CFString, false, false, false),
            ("number", 3 as CFNumber, false, false, false),
            ("boolean", kCFBooleanTrue, false, false, false),
            ("element", element, true, false, false),
            ("value", value, false, true, false),
            ("elements", [element, AXUIElementCreateApplication(1)] as CFArray, false, false, true),
            ("empty array", [] as CFArray, false, false, true),
            ("mixed array", [element, "text" as CFString] as CFArray, false, false, false),
            ("values", [value] as CFArray, false, false, false)
        ]
        for sample in samples {
            XCTAssertEqual(WindowService.cast(sample.value, to: AXUIElement.self) != nil, sample.isElement, sample.name)
            XCTAssertEqual(WindowService.cast(sample.value, to: AXValue.self) != nil, sample.isValue, sample.name)
            XCTAssertEqual(WindowService.cast(sample.value, to: [AXUIElement].self) != nil, sample.isElements,
                           sample.name)
            XCTAssertNotNil(WindowService.cast(sample.value, to: CFTypeRef.self), sample.name)
        }
        XCTAssertEqual(WindowService.cast("text" as CFString, to: String.self), "text")
        XCTAssertNil(WindowService.cast(3 as CFNumber, to: String.self))
        XCTAssertEqual(WindowService.cast(kCFBooleanTrue, to: Bool.self), true)
        XCTAssertNil(WindowService.cast("text" as CFString, to: Bool.self))
        let elements = try XCTUnwrap(WindowService.cast([element] as CFArray, to: [AXUIElement].self))
        XCTAssertTrue(elements.elementsEqual([element]) { CFEqual($0, $1) })
    }
}

/// Tests that drive other apps through the Accessibility API. They run only when the process
/// running the tests (in practice, the terminal it was started from) is trusted for Accessibility.
@MainActor
final class WindowServiceAccessibilityTests: XCTestCase {
    private var launchedApps: [NSRunningApplication] = []
    private var documents: [URL] = []

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "the test process is not trusted for Accessibility")
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for app in launchedApps {
            app.terminate()
            if try await !waitUntilTerminated(app) {
                app.forceTerminate()
                let terminated = try await waitUntilTerminated(app)
                XCTAssertTrue(terminated, "TextEdit did not quit")
            }
        }
        documents.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func waitUntilTerminated(_ app: NSRunningApplication) async throws -> Bool {
        for _ in 0..<100 where !app.isTerminated {
            try await Task.sleep(for: .milliseconds(50))
        }
        return app.isTerminated
    }

    func testDockBadgesAreReadable() throws {
        let dock = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let reads = try XCTUnwrap(WindowService.scanDockBadges(processID: dock.processIdentifier))
        XCTAssertFalse(reads.isEmpty)
    }

    func testFullscreenDisplayRequiresWindowOnCurrentSpace() throws {
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let elements: [AXUIElement] = WindowService.attribute(kAXWindowsAttribute, of: application) ?? []
            for element in elements {
                AXUIElementSetMessagingTimeout(element, 0.05)
                var candidate = WindowService.TrackedWindow(
                    id: "fullscreen", element: element,
                    info: WindowInfo(id: "fullscreen", appID: "check", appName: "Check", title: "Check",
                                     processID: app.processIdentifier,
                                     space: WindowSpace(id: 1, index: 1, isCurrent: true)))
                guard !WindowService.fullscreenDisplays(in: [candidate], isFullscreen: { _ in true }).isEmpty else { continue }
                candidate.info.space = WindowSpace(id: 2, index: 2, isCurrent: false)
                XCTAssertTrue(WindowService.fullscreenDisplays(in: [candidate], isFullscreen: { _ in true }).isEmpty)
                return
            }
        }
        XCTFail("no on-screen window of another app to check")
    }

    func testSpacesInventoryResolvesWindowsOnOtherSpaces() throws {
        let topology = try XCTUnwrap(WindowSpaces.query())
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> WindowService.ApplicationSnapshot? in
            guard app.activationPolicy == .regular, app.processIdentifier != ownPID else { return nil }
            let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            return WindowService.ApplicationSnapshot(processID: app.processIdentifier, appID: id,
                                                     appName: app.localizedName ?? id)
        }
        var previous: [WindowService.TrackedWindow] = []
        var discoveryState: [pid_t: WindowSpaces.DiscoveryState] = [:]
        var pendingTabs: Set<CGWindowID> = []
        for pass in 0..<30 {
            let result = WindowService.scan(applications: applications, previous: previous,
                                            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                            badgeReads: nil, allSpaces: true, discoveries: discoveryState,
                                            discoveryPass: pass, pendingTabs: pendingTabs)
            previous = result.windows
            discoveryState = result.discoveries
            pendingTabs = result.pendingTabs
        }
        XCTAssertFalse(topology.spaces.filter(\.isCurrent).isEmpty)
        XCTAssertFalse(previous.isEmpty)
        let listed = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownerByWindowID = Dictionary(listed.compactMap { info -> (CGWindowID, pid_t)? in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            return (id, owner)
        }, uniquingKeysWith: { first, _ in first })
        for window in previous {
            guard let id = window.windowID else { continue }
            XCTAssertEqual(ownerByWindowID[id], window.info.processID,
                           "_AXUIElementGetWindow returned a window of another process for \(window.info.appID)")
        }

        guard let sample = previous.first(where: { !$0.info.isOnCurrentSpace }), let id = sample.windowID else { return }
        var state = WindowSpaces.DiscoveryState()
        var found = false
        for _ in 0..<30 where !found {
            found = !WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state).isEmpty
        }
        XCTAssertTrue(found, "other-space window was not resolved; cursor=\(state.cursor)")
        state.cursor = UInt64.max / 2
        XCTAssertFalse(WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state).isEmpty)
        XCTAssertEqual(state.cursor, UInt64.max / 2)
        state.windows = [:]
        state.unresolved = []
        _ = WindowSpaces.discoverWindows(pid: sample.info.processID, targets: [id], state: &state)
        XCTAssertLessThan(state.cursor, UInt64.max / 2)
    }

    func testActivationRaisesAndFocusesWindow() async throws {
        let (service, target) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        service.activate(target.id)
        try await Task.sleep(for: .seconds(2))
        assertFrontmost(target)
    }

    func testActivationOverridesSpaceFocusRestoration() async throws {
        let (service, original) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        NSApp.setActivationPolicy(.accessory)
        let space = try XCTUnwrap(original.info.space)
        XCTAssertTrue(space.isCurrent)
        var target = original
        target.info.space = WindowSpace(id: space.id, index: space.index, isCurrent: false)
        service.apply(WindowService.ScanResult(windows: [target], focusedID: nil, fullscreenScreenIDs: [],
                                               activeAppIDs: [target.info.appID], badgeReads: nil))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Activation regression check"
        defer { window.orderOut(nil) }
        var restorationObserved = false
        let restoration = Task { @MainActor in
            for _ in 0..<50 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.info.processID else { continue }
                try? await Task.sleep(for: .milliseconds(350))
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(5))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                        restorationObserved = true
                        return
                    }
                }
                return
            }
        }
        defer { restoration.cancel() }
        service.activate(target.id)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(restorationObserved, "the simulated Space focus restoration did not happen")
        assertFrontmost(target)
    }

    func testCancelledQueuedActivationKeepsNewerWindowFocused() async throws {
        let (service, target) = try await activationFixture(documentCount: 2)
        defer { service.stop() }
        let newer = try XCTUnwrap(service.tracked.last)
        XCTAssertNotEqual(newer.id, target.id)
        service.activate(newer.id)
        await service.activationTask?.value
        let appElement = AXUIElementCreateApplication(newer.info.processID)
        let before: AXUIElement? = WindowService.attribute(kAXFocusedWindowAttribute, of: appElement)
        XCTAssertEqual(before.flatMap(WindowSpaces.windowID), newer.windowID)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, newer.info.processID)

        let gate = DispatchSemaphore(value: 0)
        service.scanQueue.async { gate.wait() }
        service.activate(target.id)
        try await Task.sleep(for: .milliseconds(50))
        service.cancelActivation()
        gate.signal()
        await service.activationTask?.value
        let focused: AXUIElement? = WindowService.attribute(kAXFocusedWindowAttribute, of: appElement)
        XCTAssertEqual(focused.flatMap(WindowSpaces.windowID), newer.windowID)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, newer.info.processID)
    }

    /// Opens `documentCount` blank TextEdit documents and returns a service tracking exactly those windows.
    private func activationFixture(documentCount: Int) async throws -> (WindowService, WindowService.TrackedWindow) {
        let bundleID = "com.apple.TextEdit"
        try XCTSkipIf(!NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                      "TextEdit is already running; its windows would interfere with the fixture")
        let appURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documents.append(directory)
        let files = try (0..<documentCount).map { index in
            let file = directory.appendingPathComponent("activation-\(index).txt")
            try Data().write(to: file)
            return file.resolvingSymlinksInPath().path
        }
        let app = try await NSWorkspace.shared.open(files.map { URL(fileURLWithPath: $0) }, withApplicationAt: appURL,
                                                    configuration: NSWorkspace.OpenConfiguration())
        launchedApps.append(app)

        // TextEdit may also restore windows from an earlier session; only the fixture documents count.
        func fixtureWindows(_ result: WindowService.ScanResult) -> [WindowService.TrackedWindow] {
            result.windows.filter { window in
                guard let path = window.info.documentURL.flatMap(URL.init(string:))?.resolvingSymlinksInPath().path
                else { return false }
                return files.contains(path)
            }
        }
        // A new window gets its window ID and desktop a moment after it appears.
        func isReady(_ windows: [WindowService.TrackedWindow]) -> Bool {
            windows.count == documentCount && windows.allSatisfy { $0.windowID != nil && $0.info.space != nil }
        }
        let snapshot = [WindowService.ApplicationSnapshot(processID: app.processIdentifier, appID: bundleID,
                                                          appName: bundleID)]
        var result = WindowService.scan(applications: snapshot, previous: [], frontmostPID: nil,
                                        badgeReads: nil, allSpaces: true)
        for pass in 1..<100 where !isReady(fixtureWindows(result)) {
            try await Task.sleep(for: .milliseconds(50))
            result = WindowService.scan(applications: snapshot, previous: result.windows, frontmostPID: nil,
                                        badgeReads: nil, allSpaces: true, discoveries: result.discoveries,
                                        discoveryPass: pass, pendingTabs: result.pendingTabs)
        }
        let windows = fixtureWindows(result)
        XCTAssertTrue(isReady(windows), "TextEdit fixture windows: \(windows.map { ($0.windowID, $0.info.space) })")
        let target = try XCTUnwrap(windows.first)
        let service = WindowService()
        service.apply(WindowService.ScanResult(windows: windows, focusedID: nil, fullscreenScreenIDs: [],
                                               activeAppIDs: [bundleID], badgeReads: nil))
        return (service, target)
    }

    private func assertFrontmost(_ target: WindowService.TrackedWindow, file: StaticString = #filePath,
                                 line: UInt = #line) {
        let focused: AXUIElement? = WindowService.attribute(kAXFocusedWindowAttribute,
                                                            of: AXUIElementCreateApplication(target.info.processID))
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frontWindow = onScreen.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, target.info.processID,
                       "frontmost app", file: file, line: line)
        XCTAssertEqual(focused.flatMap(WindowSpaces.windowID), target.windowID, "focused window", file: file, line: line)
        XCTAssertEqual((frontWindow?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, target.info.processID,
                       "topmost window owner", file: file, line: line)
        XCTAssertEqual(WindowSpaces.query()?.space(for: target.windowID)?.isCurrent, true,
                       "target desktop is current", file: file, line: line)
    }
}
