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
                                 activeAppIDs: [], badgeReads: [:])
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

    private func closable(_ service: WindowService, _ id: String) -> Bool? {
        var result: Bool?
        service.canClose(id) { result = $0 }
        return result
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
        XCTAssertEqual(closable(service, "close-0"), true)
        XCTAssertEqual(closable(service, "missing"), false)
        service.close("missing")
        service.close("close-0")
        XCTAssertFalse(windows[0].isVisible)
        XCTAssertTrue(windows[1].isVisible)

        windows[1].standardWindowButton(.closeButton)?.isEnabled = false
        service.close("close-1")
        XCTAssertEqual(closable(service, "close-1"), false)
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
                                        windowID: CGWindowID(element), frame: frame)
        }
        func resolve(_ frame: CGRect?, windowID: CGWindowID? = 7, listed: [WindowService.TrackedWindow] = [],
                     previous: [WindowService.TrackedWindow], usedIDs: Set<String> = [],
                     existing: Set<CGWindowID> = Set((9001...9009).map(CGWindowID.init)), tabbed: Bool = true,
                     pending: Set<CGWindowID> = []) -> (id: String?, deferred: Set<CGWindowID>) {
            var deferred: Set<CGWindowID> = []
            let id = WindowService.newWindowID(frame: frame, windowID: windowID, processID: 1,
                                               listed: Set(listed.map(\.element)), previous: previous, usedIDs: usedIDs,
                                               existingWindowIDs: existing, isTabbed: { tabbed }, pendingTabs: pending,
                                               deferredTabs: &deferred)
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
        assertFresh(resolve(frame, previous: [moved, old, unknown, otherApp], existing: [9003, 9005, 9006]),
                    "the vanished window was closed, not hidden as a tab")
        assertFresh(resolve(frame, previous: [old], existing: []), "no window exists any more")
        assertFresh(resolve(frame, previous: [old], tabbed: false), "the new window is not a tab")
        var noWindowID = old
        noWindowID.windowID = nil
        assertFresh(resolve(frame, previous: [noWindowID]), "the vanished window cannot be checked")
        assertFresh(resolve(nil, listed: [unknown], previous: [unknown]), "unknown frame")
        let zero = tab("zero", element: 9008, frame: .zero)
        assertFresh(resolve(.zero, listed: [zero], previous: [zero]), "zero frame")
        assertFresh(resolve(empty, previous: [tab("empty", element: 9009, frame: empty)]), "empty frame")
    }

    func testFullscreenProbeRunsOnlyForVisibleDisplaySizedWindowsOnTheCurrentDesktop() {
        let displays: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                     2: CGRect(x: 1000, y: 0, width: 800, height: 600)]
        func window(_ id: String, pid: pid_t, frame: CGRect, current: Bool = true) -> WindowService.TrackedWindow {
            WindowService.TrackedWindow(id: id, element: AXUIElementCreateApplication(pid),
                                        info: WindowInfo(id: id, appID: id, appName: id, title: id, processID: pid,
                                                         space: WindowSpace(id: 1, index: 1, isCurrent: current, kind: .desktop(number: 1))),
                                        frame: frame)
        }
        let full = window("full", pid: 11, frame: CGRect(x: 0, y: 25, width: 1000, height: 775))
        let second = window("second", pid: 12, frame: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let small = window("small", pid: 13, frame: CGRect(x: 10, y: 10, width: 400, height: 300))
        let hidden = window("hidden", pid: 14, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let otherDesktop = window("other", pid: 15, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), current: false)
        let notFullscreen = window("windowed", pid: 16, frame: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let visible: [pid_t: [CGRect]] = [11: [full.frame!], 12: [second.frame!], 13: [small.frame!],
                                          15: [otherDesktop.frame!], 16: [notFullscreen.frame!]]
        var probed: [pid_t] = []
        let result = WindowService.fullscreenDisplays(
            in: [full, second, small, hidden, otherDesktop, notFullscreen], displays: displays, visibleFrames: visible,
            isFullscreen: { element in
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                probed.append(pid)
                return pid != 16
            })
        XCTAssertEqual(result, [1, 2])
        XCTAssertEqual(probed, [11, 12, 16], "AXFullScreen was probed for windows that cannot be full screen")
        XCTAssertEqual(WindowService.fullscreenDisplays(in: [full], displays: [:], visibleFrames: visible) { _ in true }, [])
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

    func testDesktopsAreNumberedPerDisplayWithoutFullScreenSpaces() {
        let displays: [[String: Any]] = [
            ["Current Space": ["id64": NSNumber(value: 12)],
             "Spaces": [["id64": NSNumber(value: 11), "type": 0], ["id64": NSNumber(value: 12), "type": 4],
                        ["id64": NSNumber(value: 13), "type": 0], ["type": 0]]],
            ["Current Space": ["id64": NSNumber(value: 22)],
             "Spaces": [["id64": NSNumber(value: 21), "type": 4], ["id64": NSNumber(value: 22), "type": 0],
                        ["id64": NSNumber(value: 23), "type": 0]]],
            ["Spaces": "not a list"]
        ]
        let spaces = WindowSpaces.spaces(fromDisplays: displays)
        XCTAssertEqual(spaces.map(\.id), [11, 12, 13, 21, 22, 23])
        XCTAssertEqual(spaces.map(\.index), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(spaces.map(\.kind), [.desktop(number: 1), .fullscreen, .desktop(number: 2),
                                            .fullscreen, .desktop(number: 1), .desktop(number: 2)])
        XCTAssertEqual(spaces.filter(\.isCurrent).map(\.id), [12, 22])
        XCTAssertEqual(WindowSpaces.spaces(fromDisplays: []), [])
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

    func testLocalWindowsArePublishedInRegistrationOrder() {
        let service = WindowService(isTrusted: { true })
        let ids = (0..<20).map { "local:\($0)" }.shuffled()
        let windows = ids.map { _ in NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false) }
        zip(windows, ids).forEach { service.registerLocalWindow($0, id: $1) }
        XCTAssertEqual(service.windows.map(\.id), ids)
        service.unregisterLocalWindow(id: ids[3])
        service.registerLocalWindow(windows[3], id: ids[3])
        XCTAssertEqual(service.windows.map(\.id), ids.filter { $0 != ids[3] } + [ids[3]])
        service.registerLocalWindow(windows[0], id: ids[0])
        XCTAssertEqual(service.windows.first?.id, ids[0], "re-registering a window moved it")
        ids.forEach(service.unregisterLocalWindow)
        XCTAssertTrue(service.windows.isEmpty)
    }

    func testClosabilityOfOtherAppsIsAnsweredOffTheMainThread() async {
        let service = WindowService(isTrusted: { true })
        service.apply(scanResult([tracked("external")]))
        let gate = DispatchSemaphore(value: 0)
        service.scanQueue.async { gate.wait() }
        var answer: Bool?
        service.canClose("external") { answer = $0 }
        XCTAssertNil(answer, "the Accessibility query ran synchronously on the main thread")
        gate.signal()
        for _ in 0..<100 where answer == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(answer, false, "a window without a close button was reported closable")
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

    func testTimerRefreshesUntilStopped() async throws {
        var checks = 0
        let service = WindowService(isTrusted: { checks += 1; return false })
        service.start()
        service.start()
        XCTAssertEqual(checks, 1, "starting twice refreshed twice")
        for _ in 0..<40 where checks < 3 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(checks, 3, "the timer did not keep refreshing")
        service.stop()
        try await Task.sleep(for: .milliseconds(100))
        let stopped = checks
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(checks, stopped, "a stopped service kept refreshing")
    }

    func testActivatingAnUnraisableWindowFinishesWithoutActivatingAnything() async throws {
        let service = WindowService(isTrusted: { true })
        defer { service.stop() }
        service.apply(scanResult([tracked("ghost")]))
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        service.activate("ghost")
        let task = try XCTUnwrap(service.activationTask)
        await task.value
        XCTAssertFalse(task.isCancelled)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
    }

    func testLocalInputCancelsAPendingActivation() async throws {
        let service = WindowService(isTrusted: { true })
        defer { service.stop() }
        service.apply(scanResult([tracked("ghost")]))
        for type in [NSEvent.EventType.keyDown, .leftMouseDown] {
            let gate = DispatchSemaphore(value: 0)
            service.scanQueue.async { gate.wait() }
            service.activate("ghost")
            let task = try XCTUnwrap(service.activationTask)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(task.isCancelled)
            let event = try XCTUnwrap(type == .keyDown
                ? NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                   keyCode: 0)
                : NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
            XCTAssertTrue(task.isCancelled, "\(type) input did not cancel the activation")
            gate.signal()
            await task.value
        }
    }

    func testTrackedWindowsWithoutACloseButtonAreNotClosed() async throws {
        let service = WindowService(isTrusted: { true })
        defer { service.stop() }
        service.apply(scanResult([tracked("ghost")]))
        let closable: Bool = await withCheckedContinuation { continuation in
            service.canClose("ghost") { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(closable)
        service.close("ghost")
        await withCheckedContinuation { continuation in service.scanQueue.async { continuation.resume() } }
        XCTAssertEqual(service.windows.map(\.id), ["ghost"])
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

    private struct FixtureAppAlreadyRunning: Error, CustomStringConvertible {
        let bundleID: String
        var description: String {
            "\(bundleID) is already running; quit it before running the tests, since its windows would interfere with the fixture"
        }
    }

    private func requireNotRunning(_ bundleID: String) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw FixtureAppAlreadyRunning(bundleID: bundleID)
        }
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

    func testSpacesInventoryResolvesWindowsOnOtherSpaces() async throws {
        let (_, fixture) = try await activationFixture(documentCount: 1)
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
                                            badgeReads: [:], allSpaces: true, discoveries: discoveryState,
                                            discoveryPass: pass, pendingTabs: pendingTabs)
            previous = result.windows
            discoveryState = result.discoveries
            pendingTabs = result.pendingTabs
        }
        XCTAssertFalse(topology.spaces.filter(\.isCurrent).isEmpty)
        XCTAssertTrue(previous.contains { $0.windowID == fixture.windowID }, "the scan missed the fixture window")
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

    func testDiscoveryStopsProbingUnresolvableWindows() throws {
        let dock = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
        let missing: CGWindowID = 0xFFFF_FFF0
        var state = WindowSpaces.DiscoveryState()
        for _ in 0..<100 where state.cursor < 200 {
            XCTAssertTrue(WindowSpaces.discoverWindows(pid: dock.processIdentifier, targets: [missing], state: &state,
                                                       maxElementID: 200).isEmpty)
        }
        XCTAssertEqual(state.cursor, 200)
        let start = ProcessInfo.processInfo.systemUptime
        _ = WindowSpaces.discoverWindows(pid: dock.processIdentifier, targets: [missing], state: &state,
                                         maxElementID: 200)
        XCTAssertEqual(state.cursor, 200, "an exhausted search kept probing")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.01)
        _ = WindowSpaces.discoverWindows(pid: dock.processIdentifier, targets: [missing, missing - 1], state: &state,
                                         maxElementID: 200)
        XCTAssertLessThanOrEqual(state.cursor, 200)
        XCTAssertEqual(state.unresolved, [missing, missing - 1], "a new target did not restart the search")
    }

    func testActivationRaisesAndFocusesWindow() async throws {
        let (service, target) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        service.activate(target.id)
        try await Task.sleep(for: .seconds(2))
        assertFrontmost(target)
    }

    func testActivationRestoresAMinimizedWindow() async throws {
        let (service, target) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        func minimized() -> Bool? { WindowService.attribute(kAXMinimizedAttribute, of: target.element) }
        XCTAssertEqual(AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue),
                       .success)
        for _ in 0..<40 where minimized() != true { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(minimized(), true, "the fixture window did not minimize")
        service.activate(target.id)
        await service.activationTask?.value
        for _ in 0..<40 where minimized() != false { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(minimized(), false, "activating a minimized window left it in the Dock")
    }

    func testClosingAnotherAppsWindowPressesItsCloseButton() async throws {
        let (service, target) = try await activationFixture(documentCount: 2)
        defer { service.stop() }
        let windowID = try XCTUnwrap(target.windowID)
        let closable: Bool = await withCheckedContinuation { continuation in
            service.canClose(target.id) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(closable)
        let app = AXUIElementCreateApplication(target.info.processID)
        func isOpen() -> Bool {
            let windows: [AXUIElement] = WindowService.attribute(kAXWindowsAttribute, of: app) ?? []
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { CFEqual($0, target.element) }
                || onScreen.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
        }
        XCTAssertTrue(isOpen(), "the fixture window was not open")
        service.close(target.id)
        for _ in 0..<60 where isOpen() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(isOpen(), "the window stayed open")
    }

    func testSidebarHidesAnotherApp() async throws {
        let (service, target) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        let app = try XCTUnwrap(NSRunningApplication(processIdentifier: target.info.processID))
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let sidebar = SidebarPanel(screen: screen, onActivate: { _ in }, canCloseWindow: { $1(true) },
                                   onCloseWindow: { _ in }, windowPinPosition: { _ in nil }, onTogglePin: { _ in },
                                   onMoveWindow: { _, _, _, _ in }, onMoveGroup: { _, _ in }, onCreateGroup: { _ in },
                                   onRenameGroup: { _, _ in }, onDeleteGroup: { _ in }, onResize: { _ in })
        defer { sidebar.close() }
        sidebar.smokeStopHoverPolling()
        sidebar.update(groups: [WindowGroup(id: GroupStore.ungroupedID, name: "Ungrouped")],
                       windowsByGroup: [GroupStore.ungroupedID: [target.info]], alwaysVisible: true,
                       fullscreen: false, language: .en)
        let row = try XCTUnwrap(sidebar.sidebarRows.first { if case .window = $0.style { return true }; return false })
        let menu = try XCTUnwrap(row.menu)
        sidebar.menuNeedsUpdate(menu)
        let hide = try XCTUnwrap(menu.items.first { $0.title == "Hide App" })
        menu.performActionForItem(at: menu.index(of: hide))
        for _ in 0..<40 where !app.isHidden { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(app.isHidden, "Hide App did not hide the app")
    }

    func testActivationHelpersBringAppsForwardFromTheBackground() async throws {
        let (service, target) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        for _ in 0..<2 {
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: target.info.processID))
            Activation.activate(app)
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, app.processIdentifier,
                           "another app was not activated")

            Activation.activateSelf()
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, getpid(),
                           "OpenContexts did not activate itself from the background")
        }
    }

    func testActivationOverridesSpaceFocusRestoration() async throws {
        let (service, original) = try await activationFixture(documentCount: 1)
        defer { service.stop() }
        NSApp.setActivationPolicy(.accessory)
        let space = try XCTUnwrap(original.info.space)
        XCTAssertTrue(space.isCurrent)
        var target = original
        target.info.space = WindowSpace(id: space.id, index: space.index, isCurrent: false, kind: space.kind)
        service.apply(WindowService.ScanResult(windows: [target], focusedID: nil, fullscreenScreenIDs: [],
                                               activeAppIDs: [target.info.appID], badgeReads: [:]))
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

    /// The tab ID heuristic relies on a hidden native tab still existing in the window server and on the
    /// selected tab exposing a tab group that a lone window does not.
    func testHiddenNativeTabExistsAndTabsExposeATabGroup() async throws {
        let bundleID = "com.apple.TextEdit"
        try requireNotRunning(bundleID)
        let appURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documents.append(directory)
        let files = try (0..<2).map { index in
            let file = directory.appendingPathComponent("tab-\(index).txt")
            try Data().write(to: file)
            return file
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-AppleWindowTabbingMode", "always"]
        let app = try await NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: configuration)
        launchedApps.append(app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        func listedWindowIDs() -> Set<CGWindowID> {
            let windows: [AXUIElement] = WindowService.attribute(kAXWindowsAttribute, of: appElement) ?? []
            return Set(windows.compactMap(WindowSpaces.windowID))
        }
        func tabs() -> [AXUIElement] {
            let windows: [AXUIElement] = WindowService.attribute(kAXWindowsAttribute, of: appElement) ?? []
            return windows.flatMap { window -> [AXUIElement] in
                let children: [AXUIElement] = WindowService.attribute(kAXChildrenAttribute, of: window) ?? []
                let groups = children.filter { WindowService.attribute(kAXRoleAttribute, of: $0) == kAXTabGroupRole }
                return groups.flatMap { group -> [AXUIElement] in
                    let items: [AXUIElement] = WindowService.attribute(kAXChildrenAttribute, of: group) ?? []
                    return items.filter { WindowService.attribute(kAXRoleAttribute, of: $0) == kAXRadioButtonRole }
                }
            }
        }
        func waitFor(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            return condition()
        }

        func hiddenTab() -> AXUIElement? {
            tabs().first { (WindowService.attribute(kAXValueAttribute, of: $0) as NSNumber?)?.boolValue != true }
        }
        let tabsAppeared = try await waitFor {
            tabs().count == 2 && listedWindowIDs().count == 1 && hiddenTab() != nil
        }
        XCTAssertTrue(tabsAppeared, "TextEdit did not open the documents as two tabs")
        let first = try XCTUnwrap(listedWindowIDs().first)
        let hidden = try XCTUnwrap(hiddenTab())
        XCTAssertEqual(AXUIElementPerformAction(hidden, kAXPressAction as CFString), .success)
        let switched = try await waitFor { listedWindowIDs().count == 1 && listedWindowIDs().first != first }
        XCTAssertTrue(switched, "selecting the other tab did not change the listed window")
        let second = try XCTUnwrap(listedWindowIDs().first)
        XCTAssertTrue(WindowService.existingWindowIDs().contains(first), "a hidden tab left the window server")
        XCTAssertTrue(WindowService.existingWindowIDs().contains(second))

        let windows: [AXUIElement] = try XCTUnwrap(WindowService.attribute(kAXWindowsAttribute, of: appElement))
        let tabbed = try XCTUnwrap(windows.first)
        XCTAssertTrue(WindowService.isInTabGroup(tabbed))
        let closeButton: AXUIElement = try XCTUnwrap(WindowService.attribute(kAXCloseButtonAttribute, of: tabbed))
        XCTAssertEqual(AXUIElementPerformAction(closeButton, kAXPressAction as CFString), .success)
        let closed = try await waitFor { listedWindowIDs() == [first] }
        XCTAssertTrue(closed, "closing the selected tab did not reveal the other one")
        let remaining: [AXUIElement] = try XCTUnwrap(WindowService.attribute(kAXWindowsAttribute, of: appElement))
        XCTAssertFalse(WindowService.isInTabGroup(try XCTUnwrap(remaining.first)), "a lone window counted as a tab")
    }

    /// Opens `documentCount` blank TextEdit documents and returns a service tracking exactly those windows.
    private func activationFixture(documentCount: Int) async throws -> (WindowService, WindowService.TrackedWindow) {
        let bundleID = "com.apple.TextEdit"
        try requireNotRunning(bundleID)
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
                                        badgeReads: [:], allSpaces: true)
        for pass in 1..<100 where !isReady(fixtureWindows(result)) {
            try await Task.sleep(for: .milliseconds(50))
            result = WindowService.scan(applications: snapshot, previous: result.windows, frontmostPID: nil,
                                        badgeReads: [:], allSpaces: true, discoveries: result.discoveries,
                                        discoveryPass: pass, pendingTabs: result.pendingTabs)
        }
        let windows = fixtureWindows(result)
        XCTAssertTrue(isReady(windows), "TextEdit fixture windows: \(windows.map { ($0.windowID, $0.info.space) })")
        let target = try XCTUnwrap(windows.first)
        let service = WindowService()
        service.apply(WindowService.ScanResult(windows: windows, focusedID: nil, fullscreenScreenIDs: [],
                                               activeAppIDs: [bundleID], badgeReads: [:]))
        return (service, target)
    }

    private static let focusHint = "(another app may have taken focus during the test)"

    private func assertFrontmost(_ target: WindowService.TrackedWindow, file: StaticString = #filePath,
                                 line: UInt = #line) {
        let focused: AXUIElement? = WindowService.attribute(kAXFocusedWindowAttribute,
                                                            of: AXUIElementCreateApplication(target.info.processID))
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frontWindow = onScreen.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, target.info.processID,
                       "frontmost app \(Self.focusHint)", file: file, line: line)
        XCTAssertEqual(focused.flatMap(WindowSpaces.windowID), target.windowID,
                       "focused window \(Self.focusHint)", file: file, line: line)
        XCTAssertEqual((frontWindow?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, target.info.processID,
                       "topmost window owner \(Self.focusHint)", file: file, line: line)
        XCTAssertEqual(WindowSpaces.query()?.space(for: target.windowID)?.isCurrent, true,
                       "target desktop is current", file: file, line: line)
    }
}
