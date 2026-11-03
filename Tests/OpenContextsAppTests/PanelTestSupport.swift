import AppKit
import OpenContextsCore
@testable import OpenContextsApp

// Probes into panel internals for the panel tests.

@MainActor
extension SidebarPanel {
    var smokeRowsAreCompact: Bool {
        let rows = stack.arrangedSubviews.compactMap { $0 as? SidebarItemView }
        return !rows.isEmpty && rows.allSatisfy(\.smokeHeightIsValid)
    }

    func smokeWindowMenusAreValid(windowIDs: [String]) -> Bool {
        let rows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return rows.count == windowIDs.count && rows.allSatisfy { row in
            guard let menu = row.menu, row.subviews.allSatisfy({ $0.menu === menu }) else { return false }
            menuNeedsUpdate(menu)
            return menu.items.first?.title == L10n.text("Pin", language: language)
                && menu.items.first?.representedObject as? String == menu.title
                && menu.items.first?.state == (windowPinPosition(menu.title) != nil ? .on : .off)
                && !menu.autoenablesItems
                && menu.items[1].title == L10n.text("Close Window", language: language)
                && menu.items[1].action == #selector(closeMenuWindow(_:))
                && menu.items[1].representedObject as? String == menu.title
                && menu.items[1].isEnabled == canCloseWindow(menu.title)
                && Array(menu.items.dropFirst(3).prefix(windowIDs.count))
                    .compactMap { $0.representedObject as? String } == windowIDs
                && menu.items.suffix(2).map(\.title) == [L10n.text("Hide App", language: language),
                                                        L10n.text("Quit App", language: language)]
        }
    }

    func smokeCloseMenuWindow(_ id: String) {
        guard let menu = sidebarRows.first(where: {
            if case .window(let rowID, _) = $0.style { return rowID == id }
            return false
        })?.menu else { return }
        menuNeedsUpdate(menu)
        closeMenuWindow(menu.items[1])
    }

    func smokeContextMenuKeepsExpanded(group: Bool) -> Bool {
        guard let rowIndex = sidebarRows.lastIndex(where: {
            if case .group = $0.style { return group }
            return !group
        }) else { return false }
        let row = sidebarRows[rowIndex]
        guard let menu = row.menu, menu.delegate === self else { return false }
        let frames = sidebarFrames()
        updateHover(pointer: CGPoint(x: frames.edge.midX, y: frames.edge.midY), now: 0)
        let outside = CGPoint(x: frames.expanded.midX, y: frames.expanded.maxY + 40)
        var stayedVisible = false
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.updateHover(pointer: outside, now: 1)
                self.updateHover(pointer: outside, now: 1.25)
                stayedVisible = self.isVisible
                self.sidebarRows[rowIndex].menu?.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: CGPoint(x: row.bounds.midX, y: row.bounds.midY), in: row)
        timer.invalidate()
        updateHover(pointer: outside, now: 2)
        updateHover(pointer: outside, now: 2.25)
        return stayedVisible && !isVisible && menu.items.count >= 2
    }

    var smokeRowHoverAppearanceIsValid: Bool {
        stack.arrangedSubviews.compactMap { $0 as? SidebarItemView }
            .allSatisfy(\.smokeHoverAppearanceIsValid)
    }

    var smokeSelectedWindowIDs: [String] {
        sidebarRows.compactMap { row in
            guard case let .window(id, _) = row.style, row.isAccessibilitySelected() else { return nil }
            return id
        }
    }

    var smokePositionLayoutIsValid: Bool {
        positionConstraints.count == 4 && positionConstraints.allSatisfy(\.isActive)
            && stackCrossAxisConstraint?.isActive == true
            && stack.orientation == (position == .bottom ? .horizontal : .vertical)
            && stack.spacing == 0
    }

    var smokeTitleVisibilityIsValid: Bool {
        let windows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !windows.isEmpty && windows.allSatisfy(\.smokeTitleVisibilityIsValid)
    }

    func smokeTooltipsAreValid(expected: [String: Bool]) -> Bool {
        contentView?.layoutSubtreeIfNeeded()
        let tooltip = SidebarTooltipPanel.shared
        let rows = sidebarRows.compactMap { row -> (row: SidebarItemView, id: String)? in
            guard case .window(let id, _) = row.style else { return nil }
            return (row, id)
        }
        guard let screen, !rows.isEmpty, Set(rows.map(\.id)) == Set(expected.keys) else { return false }
        func pointer(over row: SidebarItemView) -> NSPoint {
            convertPoint(toScreen: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
        }
        for (row, id) in rows {
            row.smokeHover(false)
            guard row.smokeNeedsTooltip == expected[id] else { return false }
            row.smokeHover(true)
            guard !tooltip.isVisible, row.smokeTooltipPending == expected[id] else { return false }
            let location = pointer(over: row)
            row.smokeFireTooltip(at: location)
            let shown = tooltip.isVisible && tooltip.owner === row
            guard shown == expected[id] else { return false }
            if shown {
                guard tooltip.smokeText == row.smokeTitle, tooltip.smokeTextFits,
                      screen.visibleFrame.contains(tooltip.frame), !tooltip.frame.contains(location) else { return false }
            }
            row.smokeHover(false)
            guard !tooltip.isVisible, !row.smokeTooltipPending else { return false }
        }
        guard let truncated = rows.first(where: { expected[$0.id] == true })?.row else { return true }
        truncated.smokeHover(true)
        truncated.smokeFireTooltip(at: pointer(over: truncated))
        guard tooltip.isVisible else { return false }
        orderOut(nil)
        let hiddenWithSidebar = !tooltip.isVisible
        truncated.smokeHover(false)
        layoutPanel()
        return hiddenWithSidebar && isVisible
    }

    func smokeWindowItemsAreValid(showsTitle: Bool, maximumWidth: CGFloat) -> Bool {
        let windows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !windows.isEmpty && windows.allSatisfy {
            $0.smokeShowsTitle == showsTitle && $0.frame.width <= maximumWidth + 0.5
        }
    }

    func smokeWindowWidthIs(_ expected: CGFloat) -> Bool {
        let windows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !windows.isEmpty && windows.allSatisfy { abs($0.frame.width - expected) <= 0.5 }
    }

    func smokeBottomItemsFit(windowCount: Int, maximumWindowWidth: CGFloat) -> Bool {
        guard position == .bottom else { return false }
        let windows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        guard windows.count == windowCount, let firstWidth = windows.first?.frame.width,
              firstWidth > 0, windows.allSatisfy({ abs($0.frame.width - firstWidth) <= 0.5
                  && $0.frame.width <= maximumWindowWidth + 0.5 }) else { return false }
        let viewport = scroll.contentView.bounds
        return !scroll.hasHorizontalScroller && !scroll.hasVerticalScroller
            && abs(viewport.minX) < 0.5
            && stack.frame.width <= scroll.contentSize.width + 0.5
            && stack.arrangedSubviews.allSatisfy {
                $0.frame.minX >= -0.5 && $0.frame.maxX <= stack.bounds.maxX + 0.5
            }
    }

    var smokeNaturalContentHeight: CGFloat { naturalContentHeight }
    var smokeHasCreateGroupButton: Bool {
        stack.arrangedSubviews.contains { $0 is CallbackButton }
    }
    var smokeRowOrder: [String] {
        sidebarRows.map {
            switch $0.style {
            case .group(let id): "g:\(id)"
            case .window(let id, _): "w:\(id)"
            }
        }
    }
    func smokeWindowIdentity(_ id: String) -> ObjectIdentifier? {
        sidebarRows.first {
            if case .window(let rowID, _) = $0.style { return rowID == id }
            return false
        }.map(ObjectIdentifier.init)
    }
    func smokeBeginDrag() { sourceDraggingChanged(true) }
    func smokePreviewWindow(_ id: String, groupID: String, beforeWindowID: String?) {
        preview(.window(id: id, groupID: groupID, beforeWindowID: beforeWindowID))
    }
    var smokeVisibleRowOrder: [String] {
        sidebarRows.filter { !$0.isHidden }.map {
            switch $0.style {
            case .group(let id): "g:\(id)"
            case .window(let id, _): "w:\(id)"
            }
        }
    }
    var smokeFirstVisibleRowStartsAtEdge: Bool {
        guard let first = sidebarRows.first(where: { !$0.isHidden }) else { return false }
        let start = position == .bottom ? first.frame.minX : first.frame.minY
        let inset = position == .bottom ? stack.edgeInsets.left : stack.edgeInsets.top
        return abs(start - inset) < 0.5
    }
    var smokeRowCoordinates: [CGFloat] {
        sidebarRows.filter { !$0.isHidden }.flatMap { row in
            [primaryMid(row.frame) - 1, primaryMid(row.frame) + 1, primaryMax(row.frame) - 1]
        }
    }
    func smokePreviewWindow(_ id: String, at coordinate: CGFloat) {
        guard let destination = windowDestination(at: coordinate),
              let drop = normalizedWindowDrop(id: id, destination: destination) else { return }
        preview(drop)
    }
    func smokeWindowSelfHitKeepsPreview(_ id: String, groupID: String) -> Bool {
        let before = smokeRowOrder
        guard let drop = normalizedWindowDrop(
            id: id, destination: (groupID: groupID, beforeWindowID: id)
        ) else { return false }
        preview(drop)
        return smokeRowOrder == before
    }
    func smokePreviewGroup(_ id: String, beforeGroupID: String?) {
        preview(.group(id: id, beforeGroupID: beforeGroupID))
    }
    func smokeDestinationExited() {
        destinationDraggingChanged(false, restorePreview: true)
    }
    func smokeDestinationEntered() {
        destinationDraggingChanged(true, restorePreview: false)
    }
    var smokeIsDragging: Bool { dragging }
    func smokeCommitPreview() {
        if let previewDrop { commit(previewDrop) }
    }
    func smokeEndDrag() { sourceDraggingChanged(false) }
    var smokeHasOverflow: Bool {
        position == .bottom
            ? naturalContentWidth > scroll.contentSize.width && stack.frame.width > scroll.contentSize.width
            : naturalContentHeight > scroll.contentSize.height && stack.frame.height > scroll.contentSize.height
    }
    var smokeVerticalScrollerIsEnabled: Bool {
        position != .bottom && scroll.hasVerticalScroller
    }

    func smokeScrollLastWindowIntoView() -> Bool {
        guard let row = stack.arrangedSubviews.compactMap({ $0 as? SidebarItemView }).last else { return false }
        row.scrollToVisible(row.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        return scroll.contentView.bounds.intersects(row.convert(row.bounds, to: scroll.contentView))
    }

    func smokeStopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    func smokeSetAnimatesVisibility(_ animates: Bool) { animatesVisibility = animates }

    func smokeSetReduceMotion(_ value: Bool?) {
        reduceMotion = value.map { value in { value } }
            ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    func smokeAdvanceReveal(by elapsed: TimeInterval) { advanceReveal(elapsed: elapsed) }

    func smokeBeginResize(at x: CGFloat) { resizeHandle.onBegin?(x) }
    func smokeResize(to x: CGFloat) { resizeHandle.onDrag?(x) }
    func smokeEndResize() { resizeHandle.onEnd?() }

    var smokeResizeHandleIsValid: Bool {
        rootView.layoutSubtreeIfNeeded()
        guard canResize else { return resizeHandle.isHidden }
        let handle = resizeHandle.convert(resizeHandle.bounds, to: rootView)
        let innerEdge = position == .left ? rootView.bounds.maxX : rootView.bounds.minX
        let atInnerEdge = position == .left ? abs(handle.maxX - innerEdge) < 0.5 : abs(handle.minX - innerEdge) < 0.5
        let topmost = effect.hitTest(NSPoint(x: handle.midX, y: handle.midY)) === resizeHandle
        return !resizeHandle.isHidden && atInnerEdge && topmost && abs(handle.width - 5) < 0.5
            && abs(handle.height - rootView.bounds.height) < 0.5
    }

    var smokeEffectWidth: CGFloat {
        rootView.layoutSubtreeIfNeeded()
        return effect.frame.width
    }
    var smokeRevealIsAnimating: Bool { revealTimer?.isValid == true }

    var smokeRevealDescription: String {
        rootView.layoutSubtreeIfNeeded()
        return "progress=\(revealProgress) target=\(revealTarget) visible=\(isVisible) alpha=\(alphaValue) animating=\(smokeRevealIsAnimating) reduceMotion=\(reduceMotion()) frame=\(frame) expanded=\(sidebarFrames().expanded) root=\(rootView.bounds) effect=\(effect.frame)"
    }

    func smokeRevealIsConsistent(progress: Double) -> Bool {
        guard abs(revealProgress - progress) < 1e-6, isVisible else { return false }
        let frames = sidebarFrames()
        let fades = reduceMotion()
        let expected = fades ? frames.expanded
            : SidebarReveal.frame(expanded: frames.expanded, edge: revealEdge, progress: progress)
        let alpha = fades ? SidebarReveal.eased(progress) : 1
        rootView.layoutSubtreeIfNeeded()
        let content = effect.frame
        let pinned = switch position {
        case .left: abs(content.maxX - rootView.bounds.maxX) < 0.5 && abs(content.width - frames.expanded.width) < 0.5
        case .right: abs(content.minX) < 0.5 && abs(content.width - frames.expanded.width) < 0.5
        case .bottom: abs(content.maxY - rootView.bounds.maxY) < 0.5 && abs(content.height - frames.expanded.height) < 0.5
        }
        let roundedToWindowPoints = abs(frame.minX - expected.minX) <= 1 && abs(frame.minY - expected.minY) <= 1
            && abs(frame.width - expected.width) <= 1 && abs(frame.height - expected.height) <= 1
        return roundedToWindowPoints && abs(Double(alphaValue) - alpha) < 0.001 && pinned
    }

    func smokeApplyBadges(_ badges: [String: String]) { updateBadges(badges) }
    func smokeBadgesAreValid(text: String, diameter: CGFloat) -> Bool {
        let rows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !rows.isEmpty && rows.allSatisfy { $0.smokeBadgeIsValid(text: text, diameter: diameter) }
    }
    var smokeDotBadgesAreValid: Bool {
        let rows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !rows.isEmpty && rows.allSatisfy(\.smokeDotBadgeIsValid)
    }

    var smokeBadgesAreHidden: Bool {
        let rows = sidebarRows.filter { if case .window = $0.style { return true }; return false }
        return !rows.isEmpty && rows.allSatisfy(\.smokeBadgeIsHidden)
    }

    var smokeBadgeLayoutDescription: String {
        sidebarRows.compactMap { $0.smokeBadgeLayoutDescription }.joined(separator: ", ")
    }

    var smokeSidebarFrames: (edge: NSRect, expanded: NSRect) { sidebarFrames() }
    var smokeIsHidden: Bool { !isVisible }
    var smokeRoundedCornersAreValid: Bool {
        let expected: CACornerMask = switch position {
        case .left: [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .right: [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .bottom: [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        return effect.layer?.maskedCorners == expected
    }

    func smokeUpdateHover(pointer: CGPoint, now: TimeInterval, dragging: Bool? = nil) {
        if let dragging { self.dragging = dragging }
        updateHover(pointer: pointer, now: now)
        layoutDocumentView()
    }

    var smokeLayoutDescription: String {
        let heights = stack.arrangedSubviews.compactMap { ($0 as? SidebarItemView)?.frame.height }
        let windowWidths = sidebarRows.compactMap { row -> CGFloat? in
            if case .window = row.style { return row.frame.width }
            return nil
        }
        let itemBounds = stack.arrangedSubviews.reduce(CGRect.null) { $0.union($1.frame) }
        return "position=\(position.rawValue) frame=\(frame) natural=\(naturalContentWidth)x\(naturalContentHeight) clip=\(scroll.contentView.bounds) stack=\(stack.frame) items=\(itemBounds) windows=\(windowWidths.min() ?? -1)...\(windowWidths.max() ?? -1) scrollers=\(scroll.hasHorizontalScroller)/\(scroll.hasVerticalScroller) rows=\(heights) constraints=\(positionConstraints.map(\.isActive)) cross=\(stackCrossAxisConstraint?.isActive == true)"
    }
}

@MainActor
extension SwitcherPanel {
    var smokeLayoutIsValid: Bool {
        guard stack.arrangedSubviews.count >= 12,
              stack.arrangedSubviews.allSatisfy({ $0.frame.height <= 28.5 }),
              stack.arrangedSubviews.compactMap({ $0 as? SwitcherRow }).allSatisfy({
                  $0.smokeColumnsAreValid && $0.smokeHitRegionsRouteToRow
                      && $0.smokeSelectionAppearanceIsValid
              }),
              let selectedRow else { return false }
        return frame.width <= 600.5
            && frame.height <= displayScreen.visibleFrame.height - 79
            && stack.frame.height > scroll.contentSize.height
            && scroll.contentView.bounds.intersects(selectedRow.convert(selectedRow.bounds, to: scroll.contentView))
    }

    var smokeLayoutDescription: String {
        let selectedRect = selectedRow.map { $0.convert($0.bounds, to: scroll.contentView) } ?? .zero
        let rows = stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }
        return "frame=\(frame) stack=\(stack.frame) clip=\(scroll.contentView.bounds) selected=\(selectedRect) columns=\(rows.filter { !$0.smokeColumnsAreValid }.count) hits=\(rows.filter { !$0.smokeHitRegionsRouteToRow }.count) rows=\(stack.arrangedSubviews.map { $0.frame.height })"
    }

    func smokeMove(to index: Int, pointer: NSPoint) {
        let rows = stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }
        guard rows.indices.contains(index) else { return }
        rows[index].smokePointerMove(pointer)
    }

    var smokeHighlightedIndices: [Int] {
        stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }.enumerated().compactMap {
            $0.element.smokeHighlighted ? $0.offset : nil
        }
    }

    var smokeHoverOrigin: NSPoint { hoverOrigin }

    var smokeSearchHeader: (query: String, count: String, empty: Bool, hasSelection: Bool) {
        (queryLabel.stringValue, countLabel.stringValue, !emptyState.isHidden, selectedRow != nil)
    }

    var smokeSearchHighlightsAreValid: Bool {
        stack.arrangedSubviews.compactMap { $0 as? SwitcherRow }.allSatisfy { $0.smokeSearchHighlightsAreValid }
    }

    var smokeSpaceHeaders: [String] {
        stack.arrangedSubviews.filter { $0.identifier?.rawValue == "space-header" }.compactMap {
            $0.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
        }
    }

    var smokeTextLayouts: [[NSRect]] {
        stack.arrangedSubviews.compactMap { ($0 as? SwitcherRow)?.smokeTextLayout }
    }
}

@MainActor
extension SidebarItemView {
    var smokeHeightIsValid: Bool {
        let expected: CGFloat = switch style {
        case .group: 32
        case .window: 25
        }
        return abs(frame.height - expected) < 0.5
    }

    var smokeTitleVisibilityIsValid: Bool {
        showsTitle == (titleLabel.superview != nil) && toolTip == nil
    }
    var smokeShowsTitle: Bool { showsTitle }
    var smokeTitle: String { titleLabel.stringValue }
    var smokeNeedsTooltip: Bool { needsTooltip }
    var smokeTooltipPending: Bool { tooltipTimer?.isValid == true }
    func smokeHover(_ hovered: Bool) { setHovered(hovered) }

    func smokeFireTooltip(at pointer: NSPoint) {
        tooltipTimer?.invalidate()
        showTooltip(at: pointer)
    }

    var smokeHoverAppearanceIsValid: Bool {
        switch style {
        case .group:
            setHovered(true)
            return (layer?.backgroundColor == nil || layer?.backgroundColor == NSColor.clear.cgColor)
                && titleLabel.textColor == .labelColor
        case .window:
            setHovered(true)
            let entered = layer?.backgroundColor == appAccentColor.cgColor
                && titleLabel.textColor == .white
            setHovered(false)
            return entered && layer?.backgroundColor == (selected ? appAccentColor : NSColor.clear).cgColor
                && titleLabel.textColor == (selected ? .white : .labelColor)
                && titleLabel.font == .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
                && layer?.cornerRadius == (selected ? 6 : 7)
                && isAccessibilitySelected() == selected
        }
    }

    func smokeBadgeIsValid(text: String, diameter: CGFloat) -> Bool {
        guard let badgeLabel, !badgeLabel.isHidden else { return false }
        layoutSubtreeIfNeeded()
        return badgeLabel.stringValue == text
            && badgeLabel.layer?.backgroundColor == NSColor.systemRed.cgColor
            && badgeWidthConstraint?.constant == diameter
            && badgeHeightConstraint?.constant == diameter
            && badgeTrailingConstraint?.constant == 3
            && badgeTopConstraint?.constant == -3
            && abs(badgeLabel.frame.width - diameter) < 0.01
            && abs(badgeLabel.frame.height - diameter) < 0.01
            && abs((badgeLabel.layer?.bounds.width ?? 0) - diameter) < 0.01
            && abs((badgeLabel.layer?.bounds.height ?? 0) - diameter) < 0.01
            && badgeLabel.layer?.cornerRadius == diameter / 2
            && iconView?.image != nil
    }

    var smokeDotBadgeIsValid: Bool {
        guard let badgeLabel, !badgeLabel.isHidden else { return false }
        layoutSubtreeIfNeeded()
        return badgeLabel.stringValue.isEmpty
            && badgeWidthConstraint?.constant == 7
            && badgeHeightConstraint?.constant == 7
            && badgeTrailingConstraint?.constant == 1
            && badgeTopConstraint?.constant == -1
            && abs(badgeLabel.frame.width - 7) < 0.01
            && abs(badgeLabel.frame.height - 7) < 0.01
            && abs((badgeLabel.layer?.bounds.width ?? 0) - 7) < 0.01
            && abs((badgeLabel.layer?.bounds.height ?? 0) - 7) < 0.01
            && badgeLabel.layer?.cornerRadius == 3.5
            && iconView?.image != nil
    }

    var smokeBadgeIsHidden: Bool { badgeLabel?.isHidden == true }

    var smokeBadgeLayoutDescription: String? {
        badgeLabel.map { "frame=\($0.frame) bounds=\($0.layer?.bounds ?? .zero) constraints=\(badgeWidthConstraint?.constant ?? -1)x\(badgeHeightConstraint?.constant ?? -1)" }
    }
}

@MainActor
extension SidebarTooltipPanel {
    var smokeText: String { label.stringValue }

    var smokeTextFits: Bool {
        guard let cell = label.cell else { return false }
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width,
                                                     height: .greatestFiniteMagnitude))
        return needed.width <= label.bounds.width + 0.5 && needed.height <= label.bounds.height + 0.5
    }
}

@MainActor
extension SwitcherRow {
    var smokeHighlighted: Bool { layer?.backgroundColor == appAccentColor.cgColor }
    func smokePointerMove(_ pointer: NSPoint) { onPointerMove(pointer) }

    var smokeColumnsAreValid: Bool {
        appLabel.alignment == .right && appLabel.frame.maxX < iconView.frame.minX
            && iconView.frame.maxX < titleLabel.frame.minX
    }

    var smokeHitRegionsRouteToRow: Bool {
        let appPoint = appLabel.convert(NSPoint(x: appLabel.bounds.midX, y: appLabel.bounds.midY), to: superview)
        let iconPoint = iconView.convert(NSPoint(x: iconView.bounds.midX, y: iconView.bounds.midY), to: superview)
        let titlePoint = titleLabel.convert(NSPoint(x: titleLabel.bounds.midX, y: titleLabel.bounds.midY), to: superview)
        return hitTest(appPoint) === self && hitTest(iconPoint) === self && hitTest(titlePoint) === self
    }

    var smokeSelectionAppearanceIsValid: Bool {
        selected
            ? layer?.backgroundColor == appAccentColor.cgColor
                && appLabel.textColor == .white && titleLabel.textColor == .white
            : layer?.backgroundColor == NSColor.clear.cgColor
                && appLabel.textColor == .labelColor && titleLabel.textColor == .labelColor
    }

    var smokeSearchHighlightsAreValid: Bool {
        var highlighted = false
        var valid = true
        let yellow = NSColor(srgbRed: 1, green: 229 / 255, blue: 138 / 255, alpha: 1)
        for label in [appLabel, titleLabel] {
            let text = label.attributedStringValue
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
                if let background = attributes[.backgroundColor] as? NSColor {
                    highlighted = true
                    valid = valid && background == yellow && attributes[.foregroundColor] as? NSColor == .black
                        && attributes[.underlineStyle] == nil
                } else {
                    valid = valid && attributes[.foregroundColor] as? NSColor == (selected ? .white : .labelColor)
                }
            }
        }
        return highlighted && valid && (selected ? smokeHighlighted : !smokeHighlighted)
    }

    var smokeTextLayout: [NSRect] {
        [appLabel, titleLabel].flatMap { label in
            [label.frame, label.attributedStringValue.boundingRect(
                with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin])]
        }
    }
}
