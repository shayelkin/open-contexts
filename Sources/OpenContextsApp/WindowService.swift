import AppKit
import ApplicationServices
import Combine
import OpenContextsCore
import OSLog

@MainActor
final class WindowService: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var appBadges: [String: String] = [:]
    @Published private(set) var hasAccessibility = false
    @Published private(set) var fullscreenScreenIDs: Set<UInt32> = []

    @Published private(set) var focusedWindowID: String?
    private(set) var hasCompletedInitialScan = false

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }

    private final class ActivationRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    struct TrackedWindow: @unchecked Sendable {
        let id: String
        let element: AXUIElement
        var info: WindowInfo
        var windowID: CGWindowID? = nil
        var frame: CGRect? = nil
    }

    struct ApplicationSnapshot: Sendable {
        let processID: pid_t
        let appID: String
        let appName: String
    }

    struct ScanResult: @unchecked Sendable {
        let windows: [TrackedWindow]
        let focusedID: String?
        let fullscreenScreenIDs: Set<UInt32>
        let activeAppIDs: Set<String>
        let badgeReads: [String: DockBadgeRead]?
        var discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:]
        var spaceSnapshot: WindowSpaces.Snapshot?
        var pendingTabs: Set<CGWindowID> = []
    }

    private enum AttributeRead<Value> {
        case value(Value)
        case noValue
        case failure(AXError)
    }

    private enum CapabilityProbe {
        case value(WindowTaskCapability)
        case invalidElement
    }

    private let logger = Logger(subsystem: "OpenContexts", category: "windows")
    private(set) var tracked: [TrackedWindow] = []
    private var localWindows: [String: WeakWindow] = [:]
    private var externalFocusedID: String?
    private var timer: Timer?
    private var scanInFlight = false
    private(set) var activationTask: Task<Void, Never>?
    private var activationRequest: ActivationRequest?
    private var includeAllSpaces = false
    private var discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:]
    private var discoveryPass = 0
    private var pendingTabs: Set<CGWindowID> = []
    private var spaceSnapshot: WindowSpaces.Snapshot?
    private var lastBadgeScanAt = -Double.infinity
    private var badgeState = DockBadgeState()
    let scanQueue = DispatchQueue(label: "OpenContexts.WindowScan", qos: .userInitiated)
    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = AXIsProcessTrusted) {
        self.isTrusted = isTrusted
    }

    func start() {
        guard timer == nil else { return }
        refresh()

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        cancelActivation()
        timer?.invalidate()
        timer = nil
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func refresh() {
        guard updateTrust() else { return }
        guard !scanInFlight else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let applications = NSWorkspace.shared.runningApplications.compactMap { application -> ApplicationSnapshot? in
            guard application.activationPolicy == .regular, application.processIdentifier != ownPID else { return nil }
            let appID = application.bundleIdentifier
                ?? application.bundleURL?.path
                ?? "pid:\(application.processIdentifier)"
            return ApplicationSnapshot(
                processID: application.processIdentifier,
                appID: appID,
                appName: application.localizedName ?? appID
            )
        }
        let now = ProcessInfo.processInfo.systemUptime
        let scanBadges = now - lastBadgeScanAt >= 2
        if scanBadges { lastBadgeScanAt = now }
        let dockPID = scanBadges
            ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            : nil
        let previous = tracked
        let allSpaces = includeAllSpaces
        let discoveryState = discoveries
        let pass = discoveryPass
        let pending = pendingTabs
        discoveryPass &+= 1
        scanInFlight = true
        scanQueue.async { [weak self] in
            let result = Self.scan(applications: applications, previous: previous,
                                   frontmostPID: frontmostPID,
                                   badgeReads: scanBadges ? dockPID.flatMap(Self.scanDockBadges) : nil,
                                   allSpaces: allSpaces, discoveries: discoveryState, discoveryPass: pass,
                                   pendingTabs: pending)
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    func setIncludeAllSpaces(_ enabled: Bool) {
        guard includeAllSpaces != enabled else { return }
        includeAllSpaces = enabled
        refresh()
    }

    /// Publishes the current trust state and clears external windows when it is missing.
    private func updateTrust() -> Bool {
        let trusted = isTrusted()
        if hasAccessibility != trusted { hasAccessibility = trusted }
        guard !trusted else { return true }
        tracked = []
        externalFocusedID = nil
        if !fullscreenScreenIDs.isEmpty { fullscreenScreenIDs = [] }
        publishWindows()
        return false
    }

    func apply(_ result: ScanResult) {
        scanInFlight = false
        guard updateTrust() else { return }

        var discoveredIDs = Set<String>()
        let discovered = result.windows.filter { discoveredIDs.insert($0.id).inserted }
        var orderedIDs = tracked.map(\.id).filter(discoveredIDs.contains)
        let known = Set(orderedIDs)
        orderedIDs.append(contentsOf: discovered.map(\.id).filter { !known.contains($0) })

        externalFocusedID = result.focusedID
        discoveries = result.discoveries
        pendingTabs = result.pendingTabs
        spaceSnapshot = result.spaceSnapshot
        if let externalFocusedID, let index = orderedIDs.firstIndex(of: externalFocusedID), index != 0 {
            orderedIDs.remove(at: index)
            orderedIDs.insert(externalFocusedID, at: 0)
        }

        let byID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        tracked = orderedIDs.compactMap { byID[$0] }
        if fullscreenScreenIDs != result.fullscreenScreenIDs { fullscreenScreenIDs = result.fullscreenScreenIDs }
        badgeState.merge(activeAppIDs: result.activeAppIDs, reads: result.badgeReads)
        if appBadges != badgeState.badges { appBadges = badgeState.badges }
        hasCompletedInitialScan = true
        publishWindows()
    }

    func activate(_ id: String) {
        cancelActivation()
        if let window = localWindows[id]?.value {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            publishWindows()
            return
        }
        guard hasAccessibility, let window = tracked.first(where: { $0.id == id }) else { return }
        let knownWindowIDs = Set(tracked.compactMap(\.windowID))
        let request = ActivationRequest()
        activationRequest = request
        activationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let task = self.activationTask
            let inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                request.cancel()
                task?.cancel()
            }
            let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
                request.cancel()
                task?.cancel()
                return event
            }
            defer {
                if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
                if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            }
            await self.raise(window, request: request)
            guard !Task.isCancelled,
                  let application = NSRunningApplication(processIdentifier: window.info.processID) else { return }
            if application.isHidden { application.unhide() }
            application.activate(options: [.activateIgnoringOtherApps])

            // Space transitions can restore their previous front app after the initial activation.
            if window.info.space?.isCurrent == false, let windowID = window.windowID {
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                for _ in 0..<15 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled, !application.isTerminated else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let outcome: (current: Bool, focused: Bool) = await withCheckedContinuation { continuation in
                        self.scanQueue.async {
                            let current = WindowSpaces.query()?.space(for: windowID)?.isCurrent == true
                            let app = AXUIElementCreateApplication(window.info.processID)
                            AXUIElementSetMessagingTimeout(app, 0.2)
                            let focused: AXUIElement? = Self.attribute(kAXFocusedWindowAttribute, of: app)
                            let surfaces = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                            let topWindowID = surfaces.compactMap {
                                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                            }.first(where: knownWindowIDs.contains)
                            continuation.resume(returning: (current, focused.flatMap(WindowSpaces.windowID) == windowID && topWindowID == windowID))
                        }
                    }
                    guard !Task.isCancelled else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard outcome.current else { continue }
                    if frontPID == window.info.processID && outcome.focused { continue }
                    application.activate(options: [.activateIgnoringOtherApps])
                    await self.raise(window, request: request)
                }
            }
            self.refresh()
        }
    }

    func cancelActivation() {
        activationRequest?.cancel()
        activationTask?.cancel()
    }

    private func raise(_ window: TrackedWindow, request: ActivationRequest) async {
        let logger = logger
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scanQueue.async {
                defer { continuation.resume() }
                guard !request.isCancelled else { return }
                let app = AXUIElementCreateApplication(window.info.processID)
                AXUIElementSetMessagingTimeout(app, 0.2)
                AXUIElementSetMessagingTimeout(window.element, 0.2)
                if Self.boolAttribute(kAXMinimizedAttribute, of: window.element) {
                    guard !request.isCancelled else { return }
                    AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                guard !request.isCancelled else { return }
                AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard !request.isCancelled else { return }
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
                guard !request.isCancelled else { return }
                let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                if result != .success {
                    logger.error("Failed to raise window \(window.id, privacy: .public): AX error \(result.rawValue)")
                }
            }
        }
    }

    func canClose(_ id: String) -> Bool {
        if let window = localWindows[id]?.value {
            return window.standardWindowButton(.closeButton)?.isEnabled == true
        }
        guard hasAccessibility, let window = tracked.first(where: { $0.id == id }) else { return false }
        return Self.closeButton(of: window.element) != nil
    }

    func close(_ id: String) {
        guard canClose(id) else { return }
        if let window = localWindows[id]?.value {
            window.performClose(nil)
            publishWindows()
            return
        }
        guard let window = tracked.first(where: { $0.id == id }) else { return }
        scanQueue.async { [weak self] in
            guard let button = Self.closeButton(of: window.element) else { return }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if result != .success {
                self?.logger.error("Failed to close window \(id, privacy: .public): AX error \(result.rawValue)")
            }
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    nonisolated private static func closeButton(of element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let button: AXUIElement = attribute(kAXCloseButtonAttribute, of: element) else { return nil }
        AXUIElementSetMessagingTimeout(button, 0.2)
        return boolAttribute(kAXEnabledAttribute, of: button) ? button : nil
    }

    func registerLocalWindow(_ window: NSWindow, id: String) {
        localWindows[id] = WeakWindow(window)
        publishWindows()
    }

    func unregisterLocalWindow(id: String) {
        localWindows.removeValue(forKey: id)
        publishWindows()
    }

    private func publishWindows() {
        localWindows = localWindows.filter { $0.value.value != nil }
        let localInfos = localWindows.compactMap { id, reference -> WindowInfo? in
            guard let window = reference.value else { return nil }
            let appID = Bundle.main.bundleIdentifier ?? "OpenContexts"
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "OpenContexts"
            return WindowInfo(id: id, appID: appID, appName: appName, title: window.title,
                              processID: ProcessInfo.processInfo.processIdentifier,
                              space: spaceSnapshot?.space(for: CGWindowID(exactly: window.windowNumber)))
        }
        var publishedIDs = Set<String>()
        let allInfos = (tracked.map(\.info) + localInfos).filter { publishedIDs.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: allInfos.map { ($0.id, $0) })
        var orderedIDs = windows.map(\.id).filter { byID[$0] != nil }
        let known = Set(orderedIDs)
        orderedIDs.append(contentsOf: allInfos.map(\.id).filter { !known.contains($0) })
        let localFocusedID = NSApp.isActive
            ? localWindows.first { $0.value.value?.isKeyWindow == true }?.key
            : nil
        let focusedID = localFocusedID ?? externalFocusedID
        if focusedWindowID != focusedID { focusedWindowID = focusedID }
        if let focusedID, let index = orderedIDs.firstIndex(of: focusedID), index != 0 {
            orderedIDs.remove(at: index)
            orderedIDs.insert(focusedID, at: 0)
        }
        let published = orderedIDs.compactMap { byID[$0] }
        if windows != published { windows = published }
    }

    nonisolated static func scan(
        applications: [ApplicationSnapshot],
        previous: [TrackedWindow],
        frontmostPID: pid_t?,
        badgeReads: [String: DockBadgeRead]?,
        allSpaces: Bool = false, discoveries: [pid_t: WindowSpaces.DiscoveryState] = [:], discoveryPass: Int = 0,
        pendingTabs: Set<CGWindowID> = []
    ) -> ScanResult {
        var discovered: [TrackedWindow] = []
        var deferredTabs: Set<CGWindowID> = []
        var focusedElement: AXUIElement?
        var usedIDs: Set<String> = []
        let topology = WindowSpaces.query()
        var discoveryState = discoveries.filter { pid, _ in applications.contains { $0.processID == pid } }
        for pid in Array(discoveryState.keys) {
            guard var state = discoveryState[pid] else { continue }
            state.windows = state.windows.filter { id, _ in topology?.owners[id] == pid }
            discoveryState[pid] = state
        }
        let knownIDs = Set(previous.compactMap(\.windowID)).union(discoveryState.values.flatMap { $0.windows.keys })
        let missingOwners = Set(topology?.owners.compactMap { id, pid in
            !knownIDs.contains(id) && topology?.space(for: id)?.isCurrent == false ? pid : nil
        } ?? [])
        let pendingPIDs = applications.map(\.processID).filter { missingOwners.contains($0) }
        let discoveryPID = allSpaces && !pendingPIDs.isEmpty
            ? pendingPIDs[discoveryIndex(pass: discoveryPass, count: pendingPIDs.count)] : nil

        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processID)
            AXUIElementSetMessagingTimeout(appElement, 0.2)
            let appWindowsRead: AttributeRead<[AXUIElement]> = readAttribute(kAXWindowsAttribute, of: appElement)
            var appWindows: [AXUIElement]
            switch appWindowsRead {
            case let .value(windows):
                appWindows = windows
            case .failure(.invalidUIElement):
                appWindows = []
            case .noValue, .failure:
                discovered.append(contentsOf: previous.filter { $0.info.processID == application.processID }.map {
                    var cached = $0
                    cached.info.space = topology?.space(for: cached.windowID) ?? cached.info.space
                    return cached
                })
                usedIDs.formUnion(previous.lazy.filter { $0.info.processID == application.processID }.map(\.id))
                continue
            }
            if application.processID == frontmostPID {
                focusedElement = attribute(kAXFocusedWindowAttribute, of: appElement)
            }

            for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window: AXUIElement = attribute(key, of: appElement),
                   !appWindows.contains(where: { CFEqual($0, window) }) { appWindows.append(window) }
            }
            for window in previous where window.info.processID == application.processID {
                guard let id = window.windowID,
                      topology?.membership[id] != nil,
                      !appWindows.contains(where: { CFEqual($0, window.element) }) else { continue }
                appWindows.append(window.element)
            }
            if application.processID == discoveryPID, let topology {
                let publishedIDs = Set(appWindows.compactMap(WindowSpaces.windowID))
                let targets = Set(topology.owners.compactMap { id, pid in
                    pid == application.processID && !publishedIDs.contains(id)
                        && topology.space(for: id)?.isCurrent == false ? id : nil
                })
                var state = discoveryState[application.processID, default: WindowSpaces.DiscoveryState()]
                _ = WindowSpaces.discoverWindows(pid: application.processID, targets: targets, state: &state)
                discoveryState[application.processID] = state
            }
            for element in discoveryState[application.processID]?.windows.values ?? Dictionary<CGWindowID, AXUIElement>().values {
                if !appWindows.contains(where: { CFEqual($0, element) }) { appWindows.append(element) }
            }

            for element in appWindows {
                AXUIElementSetMessagingTimeout(element, 0.2)
                guard !discovered.contains(where: { CFEqual($0.element, element) }) else { continue }

                // ponytail: linear identity matching is simpler and fast for desktop-sized window lists.
                let existing = previous.first { !usedIDs.contains($0.id) && CFEqual($0.element, element) }
                let roleState: WindowCandidateState
                let roleRead: AttributeRead<String> = readAttribute(kAXRoleAttribute, of: element)
                switch roleRead {
                case let .value(role):
                    if role == kAXWindowRole {
                        let subroleRead: AttributeRead<String> = readAttribute(kAXSubroleAttribute, of: element)
                        switch subroleRead {
                        case let .value(subrole): roleState = .attributes(role: role, subrole: subrole)
                        case .noValue: roleState = .attributes(role: role, subrole: nil)
                        case let .failure(error):
                            roleState = error == .invalidUIElement ? .notListed : .attributeReadFailed
                        }
                    } else {
                        roleState = .attributes(role: role, subrole: nil)
                    }
                case .noValue:
                    roleState = .missingRole
                case let .failure(error):
                    roleState = error == .invalidUIElement ? .notListed : .attributeReadFailed
                    if error == .invalidUIElement, var state = discoveryState[application.processID] {
                        state.windows = state.windows.filter { !CFEqual($0.value, element) }
                        discoveryState[application.processID] = state
                    }
                }

                let title: String
                let titleRead: AttributeRead<String> = readAttribute(kAXTitleAttribute, of: element)
                switch titleRead {
                case let .value(value):
                    title = value
                case .noValue:
                    title = ""
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    guard let existing else { continue }
                    title = existing.info.title
                }

                let document: String?
                let documentRead: AttributeRead<String> = readAttribute(kAXDocumentAttribute, of: element)
                switch documentRead {
                case let .value(value):
                    document = value
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    guard let existing else { continue }
                    document = existing.info.documentURL
                case .noValue:
                    let urlRead: AttributeRead<URL> = readAttribute(kAXURLAttribute, of: element)
                    switch urlRead {
                    case let .value(value):
                        document = value.absoluteString
                    case .noValue:
                        document = nil
                    case .failure(.invalidUIElement):
                        continue
                    case .failure:
                        guard let existing else { continue }
                        document = existing.info.documentURL
                    }
                }

                let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasDocument = document?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let isModal: Bool
                let modalStatusUnknown: Bool
                let modalRead: AttributeRead<Bool> = readAttribute(kAXModalAttribute, of: element)
                switch modalRead {
                case let .value(value):
                    isModal = value
                    modalStatusUnknown = false
                case .noValue:
                    isModal = false
                    modalStatusUnknown = roleState == .attributes(role: "AXWindow", subrole: "AXDialog")
                        || roleState == .attributes(role: "AXWindow", subrole: "AXSystemDialog")
                case .failure(.invalidUIElement):
                    continue
                case .failure:
                    isModal = false
                    modalStatusUnknown = true
                }

                let taskCapability: WindowTaskCapability
                switch probeTaskCapability(of: element) {
                case let .value(value):
                    taskCapability = modalStatusUnknown && value == .unsupported ? .readFailed : value
                case .invalidElement:
                    continue
                }

                guard WindowEligibilityPolicy.shouldInclude(
                    roleState,
                    hasTitle: hasTitle,
                    hasDocument: hasDocument,
                    isModal: isModal,
                    modalStatusUnknown: modalStatusUnknown,
                    taskCapability: taskCapability,
                    previouslyTracked: existing != nil
                ) else { continue }

                let windowFrame = frame(of: element)
                let windowID = existing?.windowID ?? WindowSpaces.windowID(of: element)
                guard let id = existing?.id ?? newWindowID(
                    frame: windowFrame, windowID: windowID, processID: application.processID,
                    listed: appWindows, previous: previous, usedIDs: usedIDs,
                    pendingTabs: pendingTabs, deferredTabs: &deferredTabs
                ) else { continue }
                usedIDs.insert(id)
                discovered.append(TrackedWindow(
                    id: id,
                    element: element,
                    info: WindowInfo(
                        id: id,
                        appID: application.appID,
                        appName: application.appName,
                        title: title,
                        documentURL: document,
                        processID: application.processID,
                        space: topology?.space(for: windowID)
                    ),
                    windowID: windowID,
                    frame: windowFrame
                ))
            }
        }

        let focusedID = focusedElement.flatMap { focused in
            discovered.first { CFEqual($0.element, focused) }?.id
        }
        return ScanResult(
            windows: discovered,
            focusedID: focusedID,
            fullscreenScreenIDs: fullscreenDisplays(in: discovered),
            activeAppIDs: Set(applications.map(\.appID)),
            badgeReads: badgeReads,
            discoveries: discoveryState,
            spaceSnapshot: topology,
            pendingTabs: deferredTabs
        )
    }

    /// Round-robin index for `pass`, valid for every `pass` including negative ones after `&+=` wraps.
    nonisolated static func discoveryIndex(pass: Int, count: Int) -> Int {
        Int(UInt(bitPattern: pass) % UInt(count))
    }

    /// Picks the ID for a window the previous scan did not track.
    ///
    /// Slightly tricky as it has to work around native macOS tabs: each native tab is a separate
    /// window, but only the selected tab is listed in `kAXWindowsAttribute`, hence switching tabs
    /// looks like one window closing and a new one opening. With a new ID, the sidebar would drop the
    /// row and append the new one at the end of its group.
    /// Instead, a new window inherits the ID of the one window of the same app that stopped being
    /// listed if it had exactly the same frame.
    ///
    /// Switching tabs is not atomic: we can briefly, have both listed. To work around that, the new
    /// window is held back for one scan.
    nonisolated static func newWindowID(
        frame: CGRect?, windowID: CGWindowID?, processID: pid_t, listed: [AXUIElement],
        previous: [TrackedWindow], usedIDs: Set<String>, pendingTabs: Set<CGWindowID>,
        deferredTabs: inout Set<CGWindowID>
    ) -> String? {
        guard let frame, !frame.isEmpty else { return UUID().uuidString }
        let siblings = previous.filter { $0.info.processID == processID && $0.frame == frame }
        let isListed = { (sibling: TrackedWindow) in listed.contains { CFEqual($0, sibling.element) } }
        let vanished = siblings.filter { !usedIDs.contains($0.id) && !isListed($0) }
        if vanished.count == 1 { return vanished[0].id }
        guard let windowID, !pendingTabs.contains(windowID), siblings.contains(where: isListed) else {
            return UUID().uuidString
        }
        deferredTabs.insert(windowID)
        return nil
    }

    nonisolated static func scanDockBadges(processID: pid_t) -> [String: DockBadgeRead]? {
        let dock = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(dock, 0.15)
        let rootChildren: AttributeRead<[AXUIElement]> = readAttribute(kAXChildrenAttribute, of: dock)
        guard case let .value(children) = rootChildren else { return nil }

        var pending = children.map { ($0, 0) }
        var reads: [String: DockBadgeRead] = [:]
        while let (element, depth) = pending.popLast() {
            AXUIElementSetMessagingTimeout(element, 0.15)
            let role: String? = attribute(kAXRoleAttribute, of: element)
            if role == "AXDockItem" {
                let urlRead: AttributeRead<URL> = readAttribute(kAXURLAttribute, of: element)
                guard case let .value(url) = urlRead,
                      let appID = DockBadgeState.appID(for: url) else { continue }
                let statusRead: AttributeRead<String> = readAttribute("AXStatusLabel", of: element)
                switch statusRead {
                case let .value(value): reads[appID] = .value(value)
                case .noValue: reads[appID] = .value(nil)
                case .failure: reads[appID] = .failure
                }
            } else if depth < 7 {
                let childrenRead: AttributeRead<[AXUIElement]> = readAttribute(kAXChildrenAttribute, of: element)
                if case let .value(children) = childrenRead {
                    pending.append(contentsOf: children.map { ($0, depth + 1) })
                }
            }
        }
        return reads
    }

    nonisolated static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        let read: AttributeRead<T> = readAttribute(name, of: element)
        guard case let .value(value) = read else { return nil }
        return value
    }

    nonisolated private static func readAttribute<T>(_ name: String, of element: AXUIElement) -> AttributeRead<T> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .attributeUnsupported || result == .noValue { return .noValue }
        guard result == .success else { return .failure(result) }
        guard let value else { return .noValue }
        guard let typed = cast(value, to: T.self) else { return .noValue }
        return .value(typed)
    }

    /// `as?` and `is` with CoreFoundation types are not checked at runtime and always succeed, so those casts
    /// compare the CFTypeID instead.
    nonisolated static func cast<T>(_ value: CFTypeRef, to type: T.Type) -> T? {
        switch ObjectIdentifier(type) {
        case ObjectIdentifier(AXUIElement.self):
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? value as? T : nil
        case ObjectIdentifier(AXValue.self):
            return CFGetTypeID(value) == AXValueGetTypeID() ? value as? T : nil
        case ObjectIdentifier([AXUIElement].self):
            guard CFGetTypeID(value) == CFArrayGetTypeID(), let elements = value as? [AnyObject],
                  elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return elements as? T
        default:
            return value as? T
        }
    }

    nonisolated private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool {
        let value: CFTypeRef? = attribute(name, of: element)
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    nonisolated private static func probeTaskCapability(of element: AXUIElement) -> CapabilityProbe {
        var readFailed = false
        for attributeName in [kAXMainAttribute, kAXMinimizedAttribute] {
            var settable = DarwinBoolean(false)
            let result = AXUIElementIsAttributeSettable(element, attributeName as CFString, &settable)
            if result == .success, settable.boolValue { return .value(.supported) }
            if result == .invalidUIElement { return .invalidElement }
            if result != .success, result != .attributeUnsupported, result != .noValue { readFailed = true }
        }

        let mainRead: AttributeRead<Bool> = readAttribute(kAXMainAttribute, of: element)
        switch mainRead {
        case .value(true): return .value(.supported)
        case .failure(.invalidUIElement): return .invalidElement
        case .failure: readFailed = true
        case .value(false), .noValue: break
        }

        return .value(readFailed ? .readFailed : .unsupported)
    }

    nonisolated static func fullscreenDisplays(in windows: [TrackedWindow],
        isFullscreen: (AXUIElement) -> Bool = { boolAttribute("AXFullScreen", of: $0) }) -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }

        let visibleFrames = onScreenWindowFrames()
        var result: Set<UInt32> = []
        for window in windows where window.info.isOnCurrentSpace && isFullscreen(window.element) {
            guard let frame = frame(of: window.element),
                  visibleFrames[window.info.processID]?.contains(where: {
                      $0.intersection(frame).area >= frame.area * 0.9
                  }) == true else { continue }
            if let display = displays.max(by: {
                CGDisplayBounds($0).intersection(frame).area < CGDisplayBounds($1).intersection(frame).area
            }), CGDisplayBounds(display).intersection(frame).area > 0 {
                result.insert(display)
            }
        }
        return result
    }

    nonisolated private static func onScreenWindowFrames() -> [pid_t: [CGRect]] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        for window in raw where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            result[owner, default: []].append(frame)
        }
        return result
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute, of: element),
              let size: AXValue = attribute(kAXSizeAttribute, of: element),
              AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
