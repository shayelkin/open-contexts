import AppKit
import OpenContextsCore

let appAccentColor = NSColor(srgbRed: 80 / 255, green: 151 / 255,
                            blue: 247 / 255, alpha: 1)

@MainActor
final class SidebarPanel: NSPanel, NSMenuDelegate {
    typealias WindowMove = (_ id: String, _ groupID: String, _ beforeWindowID: String?,
                            _ visibleOrderByGroup: [String: [String]]) -> Void
    typealias GroupMove = (_ id: String, _ beforeGroupID: String?) -> Void

    private var sidebarWidth = CGFloat(AppSettings.defaultSidebarWidth)
    private let edgeWidth: CGFloat = 8
    let rootView = NSView()
    let effect = NSVisualEffectView()
    let scroll = NSScrollView()
    let stack = FlippedStackView()
    private let onActivate: (String) -> Void
    let canCloseWindow: (String) -> Bool
    private let onCloseWindow: (String) -> Void
    let windowPinPosition: (String) -> Int?
    private let onTogglePin: (String) -> Void
    private let onMoveWindow: WindowMove
    private let onMoveGroup: GroupMove
    private let onCreateGroup: (String) -> Void
    private let onRenameGroup: (String, String) -> Void
    private let onDeleteGroup: (String) -> Void
    private let onResize: (CGFloat) -> Void
    let displayScreen: NSScreen
    private var alwaysVisible = false
    private var fullscreen = false
    private var enabled = true
    private var showUngrouped = true
    private var showUngroupedTitle = true
    private var showCreateGroup = true
    private var hasVisibleContent = true
    private var verticalAlignment: SidebarVerticalAlignment = .center
    private(set) var position: SidebarPosition = .right
    private var itemDisplayMode: SidebarItemDisplayMode = .iconAndTitle
    private(set) var language: AppLanguage = .system
    private var hoverState = SidebarHoverState()
    var hoverTimer: Timer?
    private var contextMenuOpen = false
    var dragging = false
    private var sourceDragging = false
    private var destinationDragging = false
    private var originalRowOrder: [SidebarItemView]?
    private var renderedGroups: [WindowGroup] = []
    private var renderedWindows: [String: [WindowInfo]] = [:]
    private var renderedPosition: SidebarPosition = .right
    private var renderedItemDisplayMode: SidebarItemDisplayMode = .iconAndTitle
    private var renderedLanguage: AppLanguage = .system
    private(set) var naturalContentHeight: CGFloat = 52
    private(set) var naturalContentWidth: CGFloat = 52
    private var pendingUpdate: PendingSidebarUpdate?
    private var iconRetryTasks: [String: Task<Void, Never>] = [:]
    private var iconRetrySchedules: [String: IconRetrySchedule] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var renderedBadges: [String: String] = [:]
    private var focusedWindowID: String?
    private(set) var positionConstraints: [NSLayoutConstraint] = []
    private(set) var stackCrossAxisConstraint: NSLayoutConstraint?
    private var bottomItemWidthConstraints: [NSLayoutConstraint] = []
    private var effectHeightConstraint: NSLayoutConstraint?
    private(set) var previewDrop: SidebarDrop?
    var animatesVisibility = true
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var revealProgress: Double = 0
    private(set) var revealTarget: Double = 0
    private(set) var revealTimer: Timer?
    private var revealTimestamp: TimeInterval = 0
    let resizeHandle = SidebarResizeHandle()
    private var resizeHandleConstraints: [NSLayoutConstraint] = []
    private var resizeStart: (width: CGFloat, pointerX: CGFloat)?

    private struct PendingSidebarUpdate {
        let groups: [WindowGroup]
        let windowsByGroup: [String: [WindowInfo]]
        let alwaysVisible: Bool
        let fullscreen: Bool
        let enabled: Bool
        let showUngrouped: Bool
        let showUngroupedTitle: Bool
        let showCreateGroup: Bool
        let verticalAlignment: SidebarVerticalAlignment
        let sidebarWidth: CGFloat
        let position: SidebarPosition
        let itemDisplayMode: SidebarItemDisplayMode
        let language: AppLanguage
    }

    enum SidebarDrop: Equatable {
        case window(id: String, groupID: String, beforeWindowID: String?)
        case group(id: String, beforeGroupID: String?)
    }

    init(screen: NSScreen, onActivate: @escaping (String) -> Void,
         canCloseWindow: @escaping (String) -> Bool, onCloseWindow: @escaping (String) -> Void,
         windowPinPosition: @escaping (String) -> Int?,
         onTogglePin: @escaping (String) -> Void,
         onMoveWindow: @escaping WindowMove, onMoveGroup: @escaping GroupMove,
         onCreateGroup: @escaping (String) -> Void,
         onRenameGroup: @escaping (String, String) -> Void,
         onDeleteGroup: @escaping (String) -> Void,
         onResize: @escaping (CGFloat) -> Void) {
        self.displayScreen = screen
        self.onActivate = onActivate
        self.canCloseWindow = canCloseWindow
        self.onCloseWindow = onCloseWindow
        self.windowPinPosition = windowPinPosition
        self.onTogglePin = onTogglePin
        self.onMoveWindow = onMoveWindow
        self.onMoveGroup = onMoveGroup
        self.onCreateGroup = onCreateGroup
        self.onRenameGroup = onRenameGroup
        self.onDeleteGroup = onDeleteGroup
        self.onResize = onResize
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.onDraggingUpdated = { [weak self] in self?.updateDragPreview($0) ?? [] }
        stack.onPerformDrag = { [weak self] in self?.performDrop($0) ?? false }
        stack.onDraggingChanged = { [weak self] active, restore in
            self?.destinationDraggingChanged(active, restorePreview: restore)
        }
        scroll.documentView = stack

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onBegin = { [weak self] in self?.beginResize(at: $0) }
        resizeHandle.onDrag = { [weak self] in self?.resize(to: $0) }
        resizeHandle.onEnd = { [weak self] in self?.endResize() }

        rootView.addSubview(effect)
        effect.addSubview(scroll)
        effect.addSubview(resizeHandle)
        contentView = rootView
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        configurePosition()
        layoutPanel()
        layoutDocumentView()
        startHoverPolling()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        SidebarTooltipPanel.shared.hide(in: self)
        super.orderOut(sender)
    }

    var isShortcutExpanded: Bool { hoverState.isShortcutExpanded }
    var canDismissShortcut: Bool { isShortcutExpanded && !contextMenuOpen && !dragging }

    func setShortcutExpanded(_ expanded: Bool) {
        hoverState.setShortcutExpanded(expanded)
        layoutPanel()
        if isShortcutExpanded {
            startHoverPolling()
        } else if !enabled {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func close() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        stopReveal()
        cancelIconRetries()
        super.close()
    }

    func update(groups: [WindowGroup], windowsByGroup: [String: [WindowInfo]],
                alwaysVisible: Bool, fullscreen: Bool, enabled: Bool = true,
                showUngrouped: Bool = true, showUngroupedTitle: Bool = true, showCreateGroup: Bool = true,
                verticalAlignment: SidebarVerticalAlignment = .center,
                sidebarWidth: CGFloat = CGFloat(AppSettings.defaultSidebarWidth),
                position: SidebarPosition = .right,
                itemDisplayMode: SidebarItemDisplayMode = .iconAndTitle,
                language: AppLanguage = .system) {
        let requestedWidth = resizeStart == nil ? sidebarWidth : self.sidebarWidth
        let presentationChanged = self.alwaysVisible != alwaysVisible || self.fullscreen != fullscreen
            || self.enabled != enabled || self.verticalAlignment != verticalAlignment
            || self.sidebarWidth != requestedWidth
        if self.enabled != enabled {
            hoverState = SidebarHoverState()
            if enabled {
                startHoverPolling()
            } else {
                hoverTimer?.invalidate()
                hoverTimer = nil
            }
        }
        self.enabled = enabled
        self.alwaysVisible = alwaysVisible
        self.fullscreen = fullscreen
        guard !dragging else {
            pendingUpdate = PendingSidebarUpdate(groups: groups, windowsByGroup: windowsByGroup,
                                                 alwaysVisible: alwaysVisible, fullscreen: fullscreen,
                                                 enabled: enabled, showUngrouped: showUngrouped,
                                                 showUngroupedTitle: showUngroupedTitle,
                                                 showCreateGroup: showCreateGroup,
                                                 verticalAlignment: verticalAlignment,
                                                 sidebarWidth: requestedWidth,
                                                 position: position, itemDisplayMode: itemDisplayMode,
                                                 language: language)
            layoutPanel()
            return
        }
        self.position = position
        let widthChanged = self.sidebarWidth != requestedWidth
        self.sidebarWidth = requestedWidth
        self.verticalAlignment = verticalAlignment
        let groupVisibilityChanged = self.showUngrouped != showUngrouped
            || self.showUngroupedTitle != showUngroupedTitle
            || self.showCreateGroup != showCreateGroup
        self.showUngrouped = showUngrouped
        self.showUngroupedTitle = showUngroupedTitle
        self.showCreateGroup = showCreateGroup
        self.itemDisplayMode = itemDisplayMode
        self.language = language
        let positionChanged = renderedPosition != position
        let displayModeChanged = renderedItemDisplayMode != itemDisplayMode
        let languageChanged = renderedLanguage != language
        if positionChanged || displayModeChanged || widthChanged {
            renderedPosition = position
            configurePosition()
        }
        if displayModeChanged { renderedItemDisplayMode = itemDisplayMode }
        if languageChanged { renderedLanguage = language }
        guard groups != renderedGroups || windowsByGroup != renderedWindows
                || positionChanged || displayModeChanged || languageChanged || groupVisibilityChanged else {
            if presentationChanged {
                if position == .bottom { configureBottomItemWidths() }
                layoutPanel()
                layoutDocumentView()
            }
            return
        }
        renderedGroups = groups
        renderedWindows = windowsByGroup
        let activeIconKeys = Set(windowsByGroup.values.flatMap { $0 }.map(applicationIconKey))
        for key in iconRetryTasks.keys.filter({ !activeIconKeys.contains($0) }) {
            iconRetryTasks.removeValue(forKey: key)?.cancel()
        }
        iconRetrySchedules = iconRetrySchedules.filter { activeIconKeys.contains($0.key) }
        iconCache = iconCache.filter { activeIconKeys.contains($0.key) }
        NSLayoutConstraint.deactivate(bottomItemWidthConstraints)
        bottomItemWidthConstraints = []
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let visibleGroups = groups.filter {
            $0.id != GroupStore.ungroupedID
                || (showUngrouped && !windowsByGroup[$0.id, default: []].isEmpty)
        }
        hasVisibleContent = !visibleGroups.isEmpty || showCreateGroup
        for group in visibleGroups {
            let header = SidebarItemView(
                title: group.id == GroupStore.ungroupedID
                    ? L10n.text("Ungrouped", language: language) : group.name,
                style: .group(id: group.id),
                onClick: nil,
                onDraggingChanged: { [weak self] in self?.sourceDraggingChanged($0) }
            )
            header.isHidden = group.id == GroupStore.ungroupedID && !showUngroupedTitle
            if group.id != GroupStore.ungroupedID {
                let menu = NSMenu()
                let rename = NSMenuItem(title: L10n.text("Rename", language: language), action: #selector(renameGroup(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = group.id
                let delete = NSMenuItem(title: L10n.text("Delete Group", language: language), action: #selector(deleteGroup(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = group.id
                menu.items = [rename, delete]
                menu.delegate = self
                header.menu = menu
            }
            stack.addArrangedSubview(header)
            constrainSidebarItem(header)

            for window in windowsByGroup[group.id, default: []] {
                let iconKey = applicationIconKey(for: window)
                let icon = iconCache[iconKey]
                    ?? (iconRetrySchedules[iconKey] == nil ? resolvedApplicationIcon(for: window) : nil)
                if let icon { iconCache[iconKey] = icon }
                let row = SidebarItemView(
                    title: window.displayTitle,
                    icon: icon ?? fallbackApplicationIcon(for: window),
                    iconKey: iconKey,
                    badgeKey: window.appID,
                    badge: renderedBadges[window.appID],
                    showsTitle: itemDisplayMode == .iconAndTitle,
                    style: .window(id: window.id, groupID: group.id),
                    onClick: { [weak self] in self?.onActivate(window.id) },
                    onDraggingChanged: { [weak self] in self?.sourceDraggingChanged($0) }
                )
                row.setSelected(window.id == focusedWindowID)
                let menu = NSMenu(title: window.id)
                menu.autoenablesItems = false
                menu.delegate = self
                row.setContextMenu(menu)
                stack.addArrangedSubview(row)
                constrainSidebarItem(row)
                if icon == nil, iconRetrySchedules[iconKey] == nil {
                    iconRetrySchedules[iconKey] = IconRetrySchedule()
                    retryApplicationIcon(for: window, iconKey: iconKey)
                }
            }
        }
        if showCreateGroup {
            let create = CallbackButton(title: L10n.text("＋ New Group", language: language)) { [weak self] in self?.createGroup() }
            stack.addArrangedSubview(create)
            constrainAuxiliaryItem(create)
        }
        let endDrop = GroupEndDropView(language: language)
        stack.addArrangedSubview(endDrop)
        constrainAuxiliaryItem(endDrop)
        if position == .bottom {
            naturalContentHeight = 44
            configureBottomItemWidths()
        } else {
            naturalContentHeight = Self.contentHeight(groupCount: visibleGroups.filter {
                $0.id != GroupStore.ungroupedID || showUngroupedTitle
            }.count,
                                                      windowCount: visibleGroups.reduce(0) {
                $0 + windowsByGroup[$1.id, default: []].count
            }, showCreateGroup: showCreateGroup)
        }
        layoutPanel()
        layoutDocumentView()
    }

    func menuWillOpen(_ menu: NSMenu) {
        contextMenuOpen = true
        updateHover(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenuOpen = false
        updateHover(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only window menus use their title as an ID; group menus keep their static items.
        guard !menu.title.isEmpty else { return }
        menu.removeAllItems()
        guard let target = renderedWindows.values.joined().first(where: { $0.id == menu.title }) else { return }
        let processID = target.processID
        let pin = NSMenuItem(title: L10n.text("Pin", language: language), action: #selector(togglePinMenuWindow(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = target.id
        pin.state = windowPinPosition(target.id) != nil ? .on : .off
        menu.addItem(pin)
        let close = NSMenuItem(title: L10n.text("Close Window", language: language),
                               action: #selector(closeMenuWindow(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = target.id
        close.isEnabled = canCloseWindow(target.id)
        menu.addItem(close)
        menu.addItem(.separator())
        let windows = renderedGroups.flatMap { renderedWindows[$0.id, default: []] }
            .filter { $0.processID == processID }
        for window in windows {
            let item = NSMenuItem(title: window.displayTitle, action: #selector(activateMenuWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window.id
            menu.addItem(item)
        }
        guard NSRunningApplication(processIdentifier: processID) != nil else { return }
        if !windows.isEmpty { menu.addItem(.separator()) }
        for (title, action) in [(L10n.text("Hide App", language: language), #selector(hideMenuApplication(_:))),
                                (L10n.text("Quit App", language: language), #selector(terminateMenuApplication(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = processID
            menu.addItem(item)
        }
    }

    @objc private func togglePinMenuWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              renderedWindows.values.joined().contains(where: { $0.id == id }) else { return }
        onTogglePin(id)
    }

    @objc func closeMenuWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              renderedWindows.values.joined().contains(where: { $0.id == id }),
              canCloseWindow(id) else { return }
        onCloseWindow(id)
    }

    @objc private func activateMenuWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              renderedWindows.values.joined().contains(where: { $0.id == id }) else { return }
        onActivate(id)
    }

    @objc private func hideMenuApplication(_ sender: NSMenuItem) {
        guard let processID = sender.representedObject as? Int32 else { return }
        NSRunningApplication(processIdentifier: processID)?.hide()
    }

    @objc private func terminateMenuApplication(_ sender: NSMenuItem) {
        guard let processID = sender.representedObject as? Int32 else { return }
        NSRunningApplication(processIdentifier: processID)?.terminate()
    }

    func updateBadges(_ badges: [String: String]) {
        guard badges != renderedBadges else { return }
        renderedBadges = badges
        sidebarRows.forEach { $0.setBadge($0.badgeKey.flatMap { badges[$0] }) }
    }

    func updateFocusedWindow(_ id: String?) {
        guard focusedWindowID != id else { return }
        focusedWindowID = id
        for row in sidebarRows {
            if case let .window(rowID, _) = row.style { row.setSelected(rowID == id) }
        }
    }

    private func retryApplicationIcon(for window: WindowInfo, iconKey: String) {
        iconRetryTasks[iconKey] = Task { [weak self] in
            while var schedule = self?.iconRetrySchedules[iconKey],
                  let delay = schedule.nextDelay() {
                self?.iconRetrySchedules[iconKey] = schedule
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                if let icon = resolvedApplicationIcon(for: window) {
                    self.iconCache[iconKey] = icon
                    self.iconRetrySchedules[iconKey]?.stop()
                    self.stack.arrangedSubviews.compactMap { $0 as? SidebarItemView }
                        .filter { $0.iconKey == iconKey }
                        .forEach { $0.setIcon(icon) }
                    self.iconRetryTasks[iconKey] = nil
                    return
                }
            }
            self?.iconRetryTasks[iconKey] = nil
        }
    }

    private func cancelIconRetries() {
        iconRetryTasks.values.forEach { $0.cancel() }
        iconRetryTasks.removeAll()
    }

    private func restartExhaustedIconRetries() {
        for window in renderedWindows.values.flatMap({ $0 }) {
            let iconKey = applicationIconKey(for: window)
            guard iconCache[iconKey] == nil, iconRetryTasks[iconKey] == nil,
                  iconRetrySchedules[iconKey]?.isExhausted == true else { continue }
            iconRetrySchedules[iconKey] = IconRetrySchedule()
            retryApplicationIcon(for: window, iconKey: iconKey)
        }
    }

    func layoutPanel() {
        guard enabled || isShortcutExpanded, hasVisibleContent else {
            hoverState = SidebarHoverState()
            if !enabled {
                hoverTimer?.invalidate()
                hoverTimer = nil
            }
            stopReveal()
            revealProgress = 0
            revealTarget = 0
            alphaValue = 1
            if isVisible { orderOut(nil) }
            return
        }
        let frames = sidebarFrames()
        let expanded = hoverState.isExpanded || dragging || contextMenuOpen || resizeStart != nil
            || (alwaysVisible && !fullscreen)
        effectHeightConstraint?.constant = frames.expanded.height
        revealTarget = expanded ? 1 : 0
        if !animatesVisibility { revealProgress = revealTarget }
        if expanded, !isVisible { restartExhaustedIconRetries() }
        applyReveal(frames)
        if revealProgress == revealTarget { stopReveal() } else { startReveal() }
    }

    // The window itself grows out of the docked edge while the content stays pinned to its inner edge,
    // so the content slides in with its blur and shadow and never spills onto a neighboring display.
    private func applyReveal(_ frames: (edge: NSRect, expanded: NSRect)) {
        guard revealProgress > 0 || revealTarget > 0 else {
            if isVisible { orderOut(nil) }
            alphaValue = 1
            if !frame.approximatelyEquals(frames.edge) { setFrame(frames.edge, display: false) }
            return
        }
        let fades = reduceMotion()
        let target = fades ? frames.expanded
            : SidebarReveal.frame(expanded: frames.expanded, edge: revealEdge, progress: revealProgress)
        alphaValue = fades ? CGFloat(SidebarReveal.eased(revealProgress)) : 1
        if !frame.approximatelyEquals(target) { setFrame(target, display: true) }
        if !isVisible { orderFrontRegardless() }
    }

    var revealEdge: SidebarReveal.Edge {
        switch position {
        case .left: .left
        case .right: .right
        case .bottom: .bottom
        }
    }

    private func startReveal() {
        guard revealTimer == nil else { return }
        revealTimestamp = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.advanceReveal(elapsed: now - self.revealTimestamp)
                self.revealTimestamp = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    func advanceReveal(elapsed: TimeInterval) {
        revealProgress = SidebarReveal.step(progress: revealProgress, toward: revealTarget, elapsed: elapsed)
        if revealProgress == revealTarget { stopReveal() }
        applyReveal(sidebarFrames())
    }

    func sidebarFrames() -> (edge: NSRect, expanded: NSRect) {
        let area = fullscreen ? displayScreen.frame : displayScreen.visibleFrame
        let height = min(naturalContentHeight, area.height)
        let y: CGFloat = switch verticalAlignment {
        case .top: area.maxY - height
        case .center: area.midY - height / 2
        case .bottom: area.minY
        }
        let expandedWidth = itemDisplayMode == .icon ? CGFloat(44) : sidebarWidth
        switch position {
        case .left:
            return (
                NSRect(x: area.minX, y: y, width: edgeWidth, height: height),
                NSRect(x: area.minX, y: y, width: expandedWidth, height: height)
            )
        case .right:
            return (
                NSRect(x: area.maxX - edgeWidth, y: y, width: edgeWidth, height: height),
                NSRect(x: area.maxX - expandedWidth, y: y, width: expandedWidth, height: height)
            )
        case .bottom:
            let width = min(naturalContentWidth, area.width)
            let x = area.midX - width / 2
            return (
                NSRect(x: x, y: area.minY, width: width, height: edgeWidth),
                NSRect(x: x, y: area.minY, width: width, height: height)
            )
        }
    }

    private func startHoverPolling() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHover(pointer: NSEvent.mouseLocation,
                                  now: ProcessInfo.processInfo.systemUptime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func updateHover(pointer: CGPoint, now: TimeInterval) {
        guard enabled || isShortcutExpanded, hasVisibleContent else { return }
        let frames = sidebarFrames()
        let trigger = SidebarHoverState.edgeTriggerFrame(edge: frames.edge, screen: displayScreen.frame,
                                                         vertical: position != .bottom)
        if hoverState.update(pointer: pointer, edgeFrame: trigger, expandedFrame: frames.expanded,
                             dragging: dragging || resizeStart != nil, menuOpen: contextMenuOpen, now: now) {
            layoutPanel()
        }
    }

    func sourceDraggingChanged(_ active: Bool) {
        sourceDragging = active
        if !active { destinationDragging = false }
        updateDraggingState()
    }

    func destinationDraggingChanged(_ active: Bool, restorePreview: Bool) {
        destinationDragging = active
        if restorePreview { restorePreviewOrder() }
        updateDraggingState()
    }

    private func updateDraggingState() {
        let active = sourceDragging || destinationDragging
        guard dragging != active else { return }
        dragging = active
        updateHover(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
        guard !active else {
            originalRowOrder = sidebarRows
            previewDrop = nil
            return
        }
        let next = pendingUpdate ?? PendingSidebarUpdate(
            groups: renderedGroups, windowsByGroup: renderedWindows,
            alwaysVisible: alwaysVisible, fullscreen: fullscreen,
            enabled: enabled, showUngrouped: showUngrouped, showUngroupedTitle: showUngroupedTitle,
            showCreateGroup: showCreateGroup,
            verticalAlignment: verticalAlignment, sidebarWidth: sidebarWidth, position: position,
            itemDisplayMode: itemDisplayMode, language: language
        )
        self.pendingUpdate = nil
        previewDrop = nil
        originalRowOrder = nil
        renderedGroups = []
        renderedWindows = [:]
        update(groups: next.groups, windowsByGroup: next.windowsByGroup,
               alwaysVisible: next.alwaysVisible, fullscreen: next.fullscreen,
               enabled: next.enabled, showUngrouped: next.showUngrouped,
               showUngroupedTitle: next.showUngroupedTitle,
               showCreateGroup: next.showCreateGroup, verticalAlignment: next.verticalAlignment,
               sidebarWidth: next.sidebarWidth,
               position: next.position, itemDisplayMode: next.itemDisplayMode,
               language: next.language)
    }

    private func restorePreviewOrder() {
        guard previewDrop != nil, let originalRowOrder,
              Set(originalRowOrder.map(ObjectIdentifier.init)) == Set(sidebarRows.map(ObjectIdentifier.init)) else {
            previewDrop = nil
            return
        }
        sidebarRows.forEach { stack.removeArrangedSubview($0) }
        for (index, row) in originalRowOrder.enumerated() { stack.insertArrangedSubview(row, at: index) }
        previewDrop = nil
        stack.needsLayout = true
        layoutDocumentView()
    }

    private func updateDragPreview(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let drop = proposedDrop(sender) else { return [] }
        preview(drop)
        return .move
    }

    func preview(_ drop: SidebarDrop) {
        if previewDrop != drop {
            previewDrop = drop
            applyPreview(drop)
        }
    }

    private func performDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = proposedDrop(sender) else { return false }
        preview(drop)
        commit(drop)
        return true
    }

    func commit(_ drop: SidebarDrop) {
        switch drop {
        case let .window(id, groupID, beforeWindowID):
            let order = Dictionary(uniqueKeysWithValues: renderedGroups.map { group in
                (group.id, visibleWindowIDs(in: group.id))
            })
            onMoveWindow(id, groupID, beforeWindowID, order)
        case let .group(id, beforeGroupID):
            if id != beforeGroupID { onMoveGroup(id, beforeGroupID) }
        }
    }

    private func visibleWindowIDs(in groupID: String) -> [String] {
        guard let header = sidebarRows.firstIndex(where: {
            if case .group(let id) = $0.style { return id == groupID }
            return false
        }) else { return [] }
        return sidebarRows.dropFirst(header + 1).prefix {
            if case .window = $0.style { return true }
            return false
        }.compactMap { row in
            if case .window(let id, _) = row.style { return id }
            return nil
        }
    }

    private func proposedDrop(_ sender: NSDraggingInfo) -> SidebarDrop? {
        let pasteboard = sender.draggingPasteboard
        let point = stack.convert(sender.draggingLocation, from: nil)
        let coordinate = position == .bottom ? point.x : point.y
        if let id = pasteboard.string(forType: .openContextsWindow),
           let destination = windowDestination(at: coordinate) {
            return normalizedWindowDrop(id: id, destination: destination)
        }
        if let id = pasteboard.string(forType: .openContextsGroup) {
            guard id != GroupStore.ungroupedID else { return nil }
            let beforeGroupID = groupDestination(at: coordinate)
            guard beforeGroupID != GroupStore.ungroupedID else { return nil }
            if beforeGroupID == id {
                guard case .group(let previewID, _)? = previewDrop, previewID == id else { return nil }
                return previewDrop
            }
            return .group(id: id, beforeGroupID: beforeGroupID)
        }
        return nil
    }

    func normalizedWindowDrop(
        id: String, destination: (groupID: String, beforeWindowID: String?)
    ) -> SidebarDrop? {
        if destination.beforeWindowID == id {
            guard case .window(let previewID, _, _)? = previewDrop, previewID == id else { return nil }
            return previewDrop
        }
        return .window(id: id, groupID: destination.groupID,
                       beforeWindowID: destination.beforeWindowID)
    }

    func windowDestination(at coordinate: CGFloat) -> (groupID: String, beforeWindowID: String?)? {
        let rows = sidebarRows
        var currentGroup: String?
        for (index, row) in rows.enumerated() {
            let nextID = rows.dropFirst(index + 1).first.flatMap { row -> String? in
                if case .window(let id, _) = row.style { return id }
                return nil
            }
            switch row.style {
            case .group(let id):
                currentGroup = id
                if !row.isHidden, coordinate <= primaryMax(row.frame) { return (id, nextID) }
            case .window(let id, _):
                guard let currentGroup else { continue }
                if coordinate <= primaryMid(row.frame) { return (currentGroup, id) }
                if coordinate <= primaryMax(row.frame) {
                    return (currentGroup, nextID)
                }
            }
        }
        return currentGroup.map { ($0, nil) }
    }

    private func groupDestination(at coordinate: CGFloat) -> String? {
        for row in sidebarRows {
            if case .group(let id) = row.style, !row.isHidden, coordinate <= primaryMid(row.frame) { return id }
        }
        return nil
    }

    func primaryMid(_ frame: NSRect) -> CGFloat {
        position == .bottom ? frame.midX : frame.midY
    }

    func primaryMax(_ frame: NSRect) -> CGFloat {
        position == .bottom ? frame.maxX : frame.maxY
    }

    var sidebarRows: [SidebarItemView] {
        stack.arrangedSubviews.compactMap { $0 as? SidebarItemView }
    }

    private func applyPreview(_ drop: SidebarDrop) {
        var rows = sidebarRows
        switch drop {
        case let .window(id, groupID, beforeWindowID):
            guard beforeWindowID != id else { return }
            guard let source = rows.first(where: {
                if case .window(let rowID, _) = $0.style { return rowID == id }
                return false
            }) else { return }
            rows.removeAll { $0 === source }
            guard let groupIndex = rows.firstIndex(where: {
                if case .group(let rowID) = $0.style { return rowID == groupID }
                return false
            }) else { return }
            let insertionIndex: Int
            if let beforeWindowID,
               let index = rows.firstIndex(where: {
                   if case .window(let rowID, _) = $0.style { return rowID == beforeWindowID }
                   return false
               }) {
                insertionIndex = index
            } else {
                insertionIndex = rows[(groupIndex + 1)...].firstIndex(where: {
                    if case .group = $0.style { return true }
                    return false
                }) ?? rows.endIndex
            }
            rows.insert(source, at: insertionIndex)
        case let .group(id, beforeGroupID):
            guard id != GroupStore.ungroupedID, beforeGroupID != GroupStore.ungroupedID,
                  id != beforeGroupID else { return }
            guard let start = rows.firstIndex(where: {
                if case .group(let rowID) = $0.style { return rowID == id }
                return false
            }) else { return }
            let end = rows[(start + 1)...].firstIndex(where: {
                if case .group = $0.style { return true }
                return false
            }) ?? rows.endIndex
            let block = Array(rows[start..<end])
            rows.removeSubrange(start..<end)
            let insertionIndex = beforeGroupID.flatMap { target in
                rows.firstIndex(where: {
                    if case .group(let rowID) = $0.style { return rowID == target }
                    return false
                })
            } ?? rows.endIndex
            rows.insert(contentsOf: block, at: insertionIndex)
        }
        sidebarRows.forEach { stack.removeArrangedSubview($0) }
        for (index, row) in rows.enumerated() { stack.insertArrangedSubview(row, at: index) }
        stack.needsLayout = true
        layoutDocumentView()
    }

    private func configurePosition() {
        NSLayoutConstraint.deactivate(positionConstraints)
        stackCrossAxisConstraint?.isActive = false
        let bottom = position == .bottom
        stack.orientation = bottom ? .horizontal : .vertical
        stack.alignment = bottom ? .centerY : .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        switch position {
        case .left:
            effect.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .right:
            effect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .bottom:
            effect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        scroll.hasVerticalScroller = !bottom
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = bottom ? .none : .automatic
        stackCrossAxisConstraint = bottom
            ? stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
            : stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        if bottom {
            let height = effect.heightAnchor.constraint(equalToConstant: sidebarFrames().expanded.height)
            effectHeightConstraint = height
            positionConstraints = [
                effect.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                effect.topAnchor.constraint(equalTo: rootView.topAnchor),
                height
            ]
        } else {
            effectHeightConstraint = nil
            positionConstraints = [
                effect.widthAnchor.constraint(equalToConstant: itemDisplayMode == .icon ? 44 : sidebarWidth),
                effect.topAnchor.constraint(equalTo: rootView.topAnchor),
                effect.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
                position == .left
                    ? effect.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
                    : effect.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
            ]
        }
        NSLayoutConstraint.activate(positionConstraints)
        stackCrossAxisConstraint?.isActive = true

        NSLayoutConstraint.deactivate(resizeHandleConstraints)
        resizeHandle.isHidden = !canResize
        resizeHandleConstraints = [
            resizeHandle.widthAnchor.constraint(equalToConstant: 5),
            resizeHandle.topAnchor.constraint(equalTo: effect.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            position == .left
                ? resizeHandle.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
                : resizeHandle.leadingAnchor.constraint(equalTo: effect.leadingAnchor)
        ]
        NSLayoutConstraint.activate(resizeHandleConstraints)
    }

    var canResize: Bool { position != .bottom && itemDisplayMode == .iconAndTitle }

    private func beginResize(at pointerX: CGFloat) {
        guard canResize else { return }
        resizeStart = (sidebarWidth, pointerX)
    }

    private func resize(to pointerX: CGFloat) {
        guard let resizeStart, canResize else { return }
        let range = CGFloat(AppSettings.sidebarWidthRange.lowerBound)...CGFloat(AppSettings.sidebarWidthRange.upperBound)
        let width = SidebarResize.width(startWidth: resizeStart.width, startPointerX: resizeStart.pointerX,
                                        pointerX: pointerX, dockedRight: position == .right, range: range)
        guard width != sidebarWidth else { return }
        sidebarWidth = width
        configurePosition()
        layoutPanel()
        layoutDocumentView()
    }

    private func endResize() {
        guard let resizeStart else { return }
        self.resizeStart = nil
        if sidebarWidth != resizeStart.width { onResize(sidebarWidth) }
        layoutPanel()
    }

    private func constrainSidebarItem(_ view: NSView) {
        if position != .bottom {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func constrainAuxiliaryItem(_ view: NSView) {
        if position != .bottom {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
    }

    private func configureBottomItemWidths() {
        guard position == .bottom else { return }
        NSLayoutConstraint.deactivate(bottomItemWidthConstraints)
        let area = fullscreen ? displayScreen.frame : displayScreen.visibleFrame
        let contentWidth = max(0, area.width - stack.edgeInsets.left - stack.edgeInsets.right)
        let windows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        let fixedViews = stack.arrangedSubviews.filter { view in
            guard !view.isHidden else { return false }
            guard let row = view as? SidebarItemView else { return true }
            if case .window = row.style { return false }
            return true
        }
        let desiredFixedWidths = fixedViews.map {
            $0 is GroupEndDropView ? 12 : min(CGFloat(AppSettings.defaultSidebarWidth), max(0, $0.fittingSize.width))
        }
        let desiredFixedTotal = desiredFixedWidths.reduce(0, +)
        let itemCount = fixedViews.count + windows.count
        let fixedBudget = windows.isEmpty || itemCount == 0 ? contentWidth
            : contentWidth * CGFloat(fixedViews.count) / CGFloat(itemCount)
        let fixedScale = desiredFixedTotal > fixedBudget && desiredFixedTotal > 0
            ? fixedBudget / desiredFixedTotal : 1
        let fixedWidths = desiredFixedWidths.map { $0 * fixedScale }
        let fixedTotal = fixedWidths.reduce(0, +)
        let maximumWindowWidth: CGFloat = itemDisplayMode == .icon ? 32 : CGFloat(AppSettings.defaultSidebarWidth)
        let windowWidth = windows.isEmpty ? 0
            : min(maximumWindowWidth, max(0, contentWidth - fixedTotal) / CGFloat(windows.count))
        bottomItemWidthConstraints = zip(fixedViews, fixedWidths).map {
            $0.0.widthAnchor.constraint(equalToConstant: $0.1)
        } + windows.map { $0.widthAnchor.constraint(equalToConstant: windowWidth) }
        NSLayoutConstraint.activate(bottomItemWidthConstraints)
        naturalContentWidth = min(area.width, stack.edgeInsets.left + stack.edgeInsets.right
                                  + fixedTotal + windowWidth * CGFloat(windows.count))
    }

    func layoutDocumentView() {
        rootView.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        if position == .bottom {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            stack.setFrameSize(NSSize(width: naturalContentWidth,
                                      height: max(scroll.contentSize.height, 1)))
        } else {
            stack.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1),
                                      height: max(naturalContentHeight, scroll.contentSize.height)))
        }
        stack.layoutSubtreeIfNeeded()
    }

    private static func contentHeight(groupCount: Int, windowCount: Int, showCreateGroup: Bool) -> CGFloat {
        12 + CGFloat(groupCount * 32 + windowCount * 25 + (showCreateGroup ? 30 : 0) + 12)
    }

    private func createGroup() {
        requestName(title: L10n.text("New Group", language: language), value: "") { [weak self] name in self?.onCreateGroup(name) }
    }

    @objc private func renameGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let name = renderedGroups.first(where: { $0.id == id })?.name ?? ""
        requestName(title: L10n.text("Rename Group", language: language), value: name) { [weak self] name in self?.onRenameGroup(id, name) }
    }

    @objc private func deleteGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onDeleteGroup(id)
    }

    private func requestName(title: String, value: String, completion: (String) -> Void) {
        let field = NSTextField(string: value)
        field.frame.size = NSSize(width: 240, height: 24)
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("OK", language: language))
        alert.addButton(withTitle: L10n.text("Cancel", language: language))
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        // The sidebar never activates the app, so the alert would otherwise not receive typing.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        completion(field.stringValue)
    }
}

@MainActor
final class SwitcherPanel: NSPanel {
    let stack = FlippedStackView()
    let scroll = NSScrollView()
    let queryLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "")
    let emptyState = NSStackView()
    private let onActivate: (String) -> Void
    private let onSelect: (String) -> Void
    let displayScreen: NSScreen
    private(set) weak var selectedRow: SwitcherRow?
    private(set) var hoverOrigin = NSEvent.mouseLocation

    init(screen: NSScreen, onActivate: @escaping (String) -> Void,
         onSelect: @escaping (String) -> Void) {
        self.displayScreen = screen
        self.onActivate = onActivate
        self.onSelect = onSelect
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .aqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let header = NSView()
        let searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        queryLabel.font = .systemFont(ofSize: 13)
        queryLabel.lineBreakMode = .byTruncatingTail
        queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator
        for view in [searchIcon, queryLabel, countLabel, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)

        let emptyIcon = NSImageView()
        emptyIcon.image = searchIcon.image
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        emptyTitle.font = .systemFont(ofSize: 13)
        emptyTitle.textColor = .secondaryLabelColor
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyHint].forEach { emptyState.addArrangedSubview($0) }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(emptyState)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),
            searchIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            queryLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            queryLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        contentView = background
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(results: [WindowSearch.Match], selectedIndex: Int, query: String = "",
              groupBySpace: Bool = false,
              totalWindowCount: Int? = nil, language: AppLanguage = .system) {
        update(results: results, selectedIndex: selectedIndex, resetHover: true,
               groupBySpace: groupBySpace, query: query, totalWindowCount: totalWindowCount, language: language)
        orderFrontRegardless()
        layoutDocumentView()
        revealSelectedRow()
    }

    func update(results: [WindowSearch.Match], selectedIndex: Int, resetHover: Bool = false,
                groupBySpace: Bool = false,
                query: String = "", totalWindowCount: Int? = nil, language: AppLanguage = .system) {
        if resetHover {
            hoverOrigin = NSEvent.mouseLocation
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        queryLabel.stringValue = query.isEmpty ? L10n.text("Type an app name or window title", language: language) : query
        queryLabel.textColor = query.isEmpty ? .secondaryLabelColor : .labelColor
        queryLabel.setAccessibilityLabel(L10n.text("Window search", language: language))
        countLabel.stringValue = L10n.format(query.isEmpty ? "%@ windows" : "%@ results",
                                            String(results.count), language: language)
        emptyTitle.stringValue = L10n.text("No matching windows", language: language)
        emptyHint.stringValue = L10n.text("Try an app name or window title", language: language)
        emptyState.isHidden = !results.isEmpty
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var selectedRow: SwitcherRow?
        var sectionCount = 0
        var previousSpaceID: UInt64?
        for (index, match) in results.enumerated() {
            let window = match.window
            if groupBySpace, index == 0 || previousSpaceID != window.space?.id {
                let title: String
                if let space = window.space {
                    title = L10n.format(space.isFullscreen ? "Full screen %@" : "Desktop %@", String(space.index), language: language)
                        + (space.isCurrent ? " · " + L10n.text("Current", language: language) : "")
                } else {
                    title = L10n.text("Current desktop", language: language)
                }
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.setContentHuggingPriority(.required, for: .horizontal)
                let line = NSBox()
                line.boxType = .separator
                let header = NSStackView(views: [label, line])
                header.identifier = NSUserInterfaceItemIdentifier("space-header")
                header.orientation = .horizontal
                header.alignment = .centerY
                header.spacing = 8
                stack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
                header.heightAnchor.constraint(equalToConstant: 26).isActive = true
                sectionCount += 1
            }
            previousSpaceID = window.space?.id
            let row = SwitcherRow(
                match: match, selected: index == selectedIndex,
                onPointerMove: { [weak self] pointer in
                    guard self?.canHover(at: pointer) == true else { return }
                    self?.onSelect(window.id)
                },
                action: { [weak self] in self?.onActivate(window.id) }
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            if index == selectedIndex { selectedRow = row }
        }

        let area = displayScreen.visibleFrame
        let width = max(320, min(600, area.width - 48))
        let height = min(max(CGFloat(totalWindowCount ?? results.count) * 28 + CGFloat(sectionCount) * 26 + 16, 100) + 40,
                         max(140, area.height - 80))
        setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                        width: width, height: height), display: true)
        layoutDocumentView()
        self.selectedRow = selectedRow
        revealSelectedRow()
    }

    func hideSwitcher() {
        orderOut(nil)
    }

    private func canHover(at pointer: NSPoint) -> Bool {
        guard pointer != hoverOrigin else { return false }
        hoverOrigin = pointer
        return true
    }

    func layoutDocumentView() {
        contentView?.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        stack.setFrameSize(NSSize(width: max(scroll.contentSize.width, 1),
                                  height: max(fitting.height, scroll.contentSize.height)))
        stack.layoutSubtreeIfNeeded()
    }

    private func revealSelectedRow() {
        guard let selectedRow else { return }
        selectedRow.scrollToVisible(selectedRow.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
private final class BadgeLabel: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

@MainActor
final class SidebarItemView: NSView, NSDraggingSource {
    enum Style {
        case group(id: String)
        case window(id: String, groupID: String)
    }

    let style: Style
    fileprivate let iconKey: String?
    fileprivate let badgeKey: String?
    let titleLabel: NSTextField
    private(set) weak var iconView: NSImageView?
    private(set) weak var badgeLabel: NSTextField?
    let showsTitle: Bool
    private(set) var badgeWidthConstraint: NSLayoutConstraint?
    private(set) var badgeHeightConstraint: NSLayoutConstraint?
    private(set) var badgeTrailingConstraint: NSLayoutConstraint?
    private(set) var badgeTopConstraint: NSLayoutConstraint?
    private let onClick: (() -> Void)?
    private let onDraggingChanged: (Bool) -> Void
    private var mouseDownPoint: NSPoint?
    private(set) var dragging = false
    private var trackingArea: NSTrackingArea?
    private(set) var selected = false
    private var hovered = false
    private(set) var tooltipTimer: Timer?

    init(title: String, icon: NSImage? = nil, iconKey: String? = nil,
         badgeKey: String? = nil, badge: String? = nil,
         showsTitle: Bool = true,
         style: Style, onClick: (() -> Void)?,
         onDraggingChanged: @escaping (Bool) -> Void) {
        self.style = style
        self.iconKey = iconKey
        self.badgeKey = badgeKey
        self.showsTitle = showsTitle
        self.onClick = onClick
        self.onDraggingChanged = onDraggingChanged
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        setAccessibilityRole(onClick == nil ? .group : .button)
        setAccessibilityLabel(title)
        if case .group = style { toolTip = title }

        titleLabel.font = switch style {
        case .group: .systemFont(ofSize: 12, weight: .semibold)
        case .window: .systemFont(ofSize: 13, weight: .regular)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        if showsTitle { addSubview(titleLabel) }

        let leading: CGFloat = 4
        var constraints: [NSLayoutConstraint] = []
        if showsTitle {
            let trailing = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
            trailing.priority = .defaultHigh
            constraints += [
                trailing,
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ]
        }
        if let icon {
            let imageView = NSImageView(image: icon)
            iconView = imageView
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            let badgeLabel = BadgeLabel(labelWithString: "")
            self.badgeLabel = badgeLabel
            badgeLabel.alignment = .center
            badgeLabel.font = .systemFont(ofSize: 8, weight: .semibold)
            badgeLabel.textColor = .white
            badgeLabel.wantsLayer = true
            badgeLabel.layer?.backgroundColor = NSColor.systemRed.cgColor
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badgeLabel)
            let width = badgeLabel.widthAnchor.constraint(equalToConstant: 7)
            let height = badgeLabel.heightAnchor.constraint(equalToConstant: 7)
            let trailing = badgeLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 3)
            let top = badgeLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -3)
            badgeWidthConstraint = width
            badgeHeightConstraint = height
            badgeTrailingConstraint = trailing
            badgeTopConstraint = top
            constraints += [
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                trailing,
                top,
                width,
                height,
            ]
            if showsTitle {
                let imageLeading = imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
                imageLeading.priority = .defaultHigh
                constraints += [
                    imageLeading,
                    titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7)
                ]
            } else {
                constraints.append(imageView.centerXAnchor.constraint(equalTo: centerXAnchor))
            }
        } else {
            if showsTitle {
                constraints.append(titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading))
            }
        }
        let height: CGFloat = switch style {
        case .group: 32
        case .window: 25
        }
        constraints.append(heightAnchor.constraint(equalToConstant: height))
        NSLayoutConstraint.activate(constraints)
        setBadge(badge)
        updateAppearance()
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        updateAppearance()
    }

    func setIcon(_ icon: NSImage) {
        iconView?.image = icon
    }

    func setContextMenu(_ menu: NSMenu) {
        self.menu = menu
        subviews.forEach { $0.menu = menu }
    }

    func setBadge(_ value: String?) {
        guard let badgeLabel else { return }
        guard let value else {
            badgeLabel.isHidden = true
            return
        }
        let isDot = value == "•"
        badgeLabel.stringValue = isDot ? "" : value
        let diameter: CGFloat = isDot ? 7 : max(12, min(20, CGFloat(value.count * 5 + 5)))
        badgeWidthConstraint?.constant = diameter
        badgeHeightConstraint?.constant = diameter
        badgeTrailingConstraint?.constant = isDot ? 1 : 3
        badgeTopConstraint?.constant = isDot ? -1 : -3
        badgeLabel.layer?.cornerRadius = diameter / 2
        badgeLabel.isHidden = false
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        setHovered(pointer.map { visibleRect.contains($0) } ?? false)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        hideTooltip()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideTooltip() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let origin = mouseDownPoint else { return }
        if case .group(let id) = style, id == GroupStore.ungroupedID { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 3 else { return }
        dragging = true
        let item = NSPasteboardItem()
        switch style {
        case .group(let id): item.setString(id, forType: .openContextsGroup)
        case .window(let id, _): item.setString(id, forType: .openContextsWindow)
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: draggingImage())
        onDraggingChanged(true)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDraggingChanged(false)
    }

    private func draggingImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func setHovered(_ hovered: Bool) {
        let changed = self.hovered != hovered
        self.hovered = hovered
        updateAppearance()
        if changed { scheduleTooltip() }
    }

    var needsTooltip: Bool {
        guard case .window = style else { return false }
        return SidebarTooltipLayout.needsTooltip(showsTitle: showsTitle,
                                                 titleWidth: titleLabel.intrinsicContentSize.width,
                                                 availableWidth: titleLabel.bounds.width)
    }

    private func scheduleTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        guard hovered, needsTooltip else {
            SidebarTooltipPanel.shared.hide(for: self)
            return
        }
        let delay = SidebarTooltipLayout.initialDelay(
            milliseconds: UserDefaults.standard.object(forKey: SidebarTooltipLayout.initialDelayDefaultsKey))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTooltip(at: NSEvent.mouseLocation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        tooltipTimer = timer
    }

    func showTooltip(at pointer: NSPoint) {
        tooltipTimer = nil
        guard hovered, !dragging, needsTooltip, let window, window.isVisible, let screen = window.screen else { return }
        SidebarTooltipPanel.shared.show(titleLabel.stringValue, for: self, at: pointer, on: screen)
    }

    private func hideTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        SidebarTooltipPanel.shared.hide(for: self)
    }

    private func updateAppearance() {
        guard case .window = style else { return }
        let highlighted = selected || hovered
        layer?.backgroundColor = highlighted ? appAccentColor.cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = selected ? 6 : 7
        titleLabel.textColor = highlighted ? .white : .labelColor
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        setAccessibilitySelected(selected)
    }
}

@MainActor
final class SidebarResizeHandle: NSView {
    var onBegin: ((CGFloat) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var resizing = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !resizing { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        resizing = true
        onBegin?(NSEvent.mouseLocation.x)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation.x) }

    override func mouseUp(with event: NSEvent) {
        resizing = false
        onEnd?()
        if !hovered { NSCursor.arrow.set() }
    }
}

// AppKit only shows `toolTip` while the app is active. OpenContexts is an LSUIElement app whose
// sidebar is a non-activating panel, so it is almost never active and standard tooltips never appear;
// this panel draws them ourselves from hover tracking that works regardless of activation.
@MainActor
final class SidebarTooltipPanel: NSPanel {
    static let shared = SidebarTooltipPanel()
    private static let maximumTextWidth: CGFloat = 360
    private static let padding = NSSize(width: 6, height: 3)
    let label = NSTextField(wrappingLabelWithString: "")
    private(set) weak var owner: NSView?

    private init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 5
        effect.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        effect.addSubview(label)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ text: String, for owner: NSView, at pointer: NSPoint, on screen: NSScreen) {
        guard let cell = label.cell else { return }
        self.owner = owner
        label.stringValue = text
        let area = screen.visibleFrame
        let padding = Self.padding
        let textWidth = min(Self.maximumTextWidth, area.width - padding.width * 2)
        let textSize = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
                                                       height: .greatestFiniteMagnitude))
        let size = NSSize(width: ceil(textSize.width) + padding.width * 2,
                          height: ceil(textSize.height) + padding.height * 2)
        let target = SidebarTooltipLayout.frame(size: size, pointer: pointer, screen: area)
        label.frame = NSRect(x: padding.width, y: padding.height,
                             width: target.width - padding.width * 2, height: target.height - padding.height * 2)
        setFrame(target, display: true)
        invalidateShadow()
        orderFrontRegardless()
    }

    func hide(for owner: NSView) {
        guard owner === self.owner else { return }
        hide()
    }

    func hide(in window: NSWindow) {
        guard owner?.window === window else { return }
        hide()
    }

    private func hide() {
        owner = nil
        orderOut(nil)
    }
}

@MainActor
final class SwitcherRow: NSButton {
    private let callback: () -> Void
    let appLabel: NSTextField
    let iconView: NSImageView
    let titleLabel: NSTextField
    let selected: Bool
    let onPointerMove: (NSPoint) -> Void
    private var trackingArea: NSTrackingArea?

    init(match: WindowSearch.Match, selected: Bool, onPointerMove: @escaping (NSPoint) -> Void,
         action: @escaping () -> Void) {
        let window = match.window
        callback = action
        self.onPointerMove = onPointerMove
        appLabel = NSTextField(labelWithString: window.appName)
        iconView = NSImageView(image: applicationIcon(for: window))
        titleLabel = NSTextField(labelWithString: window.displayTitle)
        self.selected = selected
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? appAccentColor.cgColor : NSColor.clear.cgColor
        let textColor = selected ? NSColor.white : NSColor.labelColor
        appLabel.alignment = .right
        appLabel.font = .systemFont(ofSize: 13)
        appLabel.textColor = textColor
        appLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        titleLabel.textColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        for (label, ranges) in [(appLabel, match.appRanges), (titleLabel, match.titleRanges)] where !ranges.isEmpty {
            let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
            for range in ranges {
                text.addAttributes([.backgroundColor: NSColor(srgbRed: 1, green: 229 / 255,
                                                              blue: 138 / 255, alpha: 1),
                                    .foregroundColor: NSColor.black], range: range)
            }
            label.attributedStringValue = text
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.imageScaling = .scaleProportionallyDown
        [appLabel, iconView, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            appLabel.widthAnchor.constraint(equalToConstant: 150),
            iconView.leadingAnchor.constraint(equalTo: appLabel.trailingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        target = self
        self.action = #selector(invoke)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setAccessibilityLabel("\(window.appName), \(window.displayTitle)")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                          owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) { selectUnderPointer(event) }
    override func mouseMoved(with event: NSEvent) { selectUnderPointer(event) }

    private func selectUnderPointer(_ event: NSEvent) {
        guard let window, visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPointerMove(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    @objc private func invoke() { callback() }
}

@MainActor
final class FlippedStackView: NSStackView {
    var onDraggingUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onPerformDrag: ((NSDraggingInfo) -> Bool)?
    var onDraggingChanged: ((_ active: Bool, _ restorePreview: Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.openContextsWindow, .openContextsGroup])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.openContextsWindow, .openContextsGroup])
    }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingChanged?(true, false)
        return onDraggingUpdated?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDrag?(sender) ?? false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingChanged?(false, true)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDraggingChanged?(false, false)
    }
}

@MainActor
private final class GroupEndDropView: NSView {
    init(language: AppLanguage) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 12).isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Move group to end", language: language))
    }

    required init?(coder: NSCoder) { nil }

}

@MainActor
final class CallbackButton: NSButton {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .recessed
        isBordered = false
        alignment = .left
        target = self
        action = #selector(invoke)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invoke() { callback() }
}

private extension NSPasteboard.PasteboardType {
    static let openContextsWindow = Self("com.opencontexts.window")
    static let openContextsGroup = Self("com.opencontexts.group")
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.5 && abs(minY - other.minY) < 0.5
            && abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}

@MainActor
private func applicationIcon(for window: WindowInfo) -> NSImage {
    resolvedApplicationIcon(for: window) ?? fallbackApplicationIcon(for: window)
}

private func applicationIconKey(for window: WindowInfo) -> String {
    "\(window.processID):\(window.appID)"
}

@MainActor
private func resolvedApplicationIcon(for window: WindowInfo) -> NSImage? {
    let source = NSRunningApplication(processIdentifier: window.processID)?.icon
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: window.appID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    guard let source else { return nil }
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 24, height: 24)
    return icon
}

@MainActor
private func fallbackApplicationIcon(for window: WindowInfo) -> NSImage {
    let source = NSImage(systemSymbolName: "macwindow", accessibilityDescription: window.displayTitle)
        ?? NSImage(size: NSSize(width: 24, height: 24))
    let icon = (source.copy() as? NSImage) ?? source
    icon.size = NSSize(width: 24, height: 24)
    return icon
}
