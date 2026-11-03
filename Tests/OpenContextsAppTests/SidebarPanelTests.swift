import AppKit
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

@MainActor
final class SidebarPanelTests: XCTestCase {
    private var screen: NSScreen!
    private var sidebar: SidebarPanel!
    private var windows: [WindowInfo] = []
    private let groups = [WindowGroup(id: GroupStore.ungroupedID, name: "未分组")]
    private var area: NSRect { screen.visibleFrame }
    private var windowMoves: [(String, String, String?)] = []
    private var groupMoves: [(String, String?)] = []
    private var closedWindowIDs: [String] = []
    private var resizedWidths: [CGFloat] = []

    private let firstGroupID = "smoke-group-1"
    private let secondGroupID = "smoke-group-2"
    private var dragGroups: [WindowGroup] {
        [
            WindowGroup(id: GroupStore.ungroupedID, name: "未分组"),
            WindowGroup(id: firstGroupID, name: "Group 1"),
            WindowGroup(id: secondGroupID, name: "Group 2")
        ]
    }
    private var coordinateWindows: [String: [WindowInfo]] {
        [
            GroupStore.ungroupedID: [windows[4], windows[5]],
            firstGroupID: [windows[6], windows[7]],
            secondGroupID: [windows[8], windows[9]]
        ]
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        sidebar = SidebarPanel(
            screen: screen,
            onActivate: { _ in },
            canCloseWindow: { $0 != "smoke-2" },
            onCloseWindow: { [unowned self] in self.closedWindowIDs.append($0) },
            windowPinPosition: { $0 == "smoke-1" ? 1 : nil },
            onTogglePin: { _ in },
            onMoveWindow: { [unowned self] id, groupID, beforeID, _ in self.windowMoves.append((id, groupID, beforeID)) },
            onMoveGroup: { [unowned self] in self.groupMoves.append(($0, $1)) },
            onCreateGroup: { _ in },
            onRenameGroup: { _, _ in },
            onDeleteGroup: { _ in },
            onResize: { [unowned self] in self.resizedWidths.append($0) }
        )
        sidebar.smokeStopHoverPolling()
        sidebar.smokeSetAnimatesVisibility(false)
        windows = (0..<200).map {
            WindowInfo(id: "smoke-\($0)", appID: "smoke", appName: "Smoke",
                       title: "Window \($0) " + String(repeating: "Long title ", count: 40),
                       processID: ProcessInfo.processInfo.processIdentifier)
        }
    }

    override func tearDown() async throws {
        sidebar.close()
        sidebar = nil
    }

    /// Height of the always-visible right sidebar with a single window.
    private func singleWindowHeight() -> CGFloat {
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        return sidebar.frame.height
    }

    func testNaturalHeightGrowsWithWindowCount() {
        var measuredHeights: [Int: CGFloat] = [:]
        for count in [0, 1, 3] {
            sidebar.update(groups: groups,
                           windowsByGroup: [GroupStore.ungroupedID: Array(windows.prefix(count))],
                           alwaysVisible: true, fullscreen: false, position: .right)
            sidebar.contentView?.layoutSubtreeIfNeeded()
            measuredHeights[count] = sidebar.frame.height
            guard naturalHeightIsValid(sidebar, in: area), (count == 0 || sidebar.smokeRowsAreCompact),
                  sidebar.smokeRowHoverAppearanceIsValid, sidebar.smokePositionLayoutIsValid else {
                return XCTFail("sidebar natural height mismatch count=\(count): \(sidebar.smokeLayoutDescription)")
            }
        }
        guard let zeroHeight = measuredHeights[0], let oneHeight = measuredHeights[1],
              let threeHeight = measuredHeights[3], zeroHeight < oneHeight, oneHeight < threeHeight else {
            return XCTFail("sidebar natural heights did not grow: \(measuredHeights)")
        }
    }

    func testFocusedWindowHighlightIsKeptAcrossUpdates() {
        for position in SidebarPosition.allCases {
            for displayMode in SidebarItemDisplayMode.allCases {
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: Array(windows.prefix(3))],
                               alwaysVisible: true, fullscreen: false, position: position,
                               itemDisplayMode: displayMode)
                sidebar.updateFocusedWindow(windows[0].id)
                let identity = sidebar.smokeWindowIdentity(windows[0].id)
                guard sidebar.smokeSelectedWindowIDs == [windows[0].id], sidebar.smokeRowHoverAppearanceIsValid else {
                    return XCTFail("active sidebar window did not retain switcher styling after mouse exit")
                }
                sidebar.updateFocusedWindow(windows[1].id)
                guard sidebar.smokeSelectedWindowIDs == [windows[1].id], sidebar.smokeRowHoverAppearanceIsValid,
                      sidebar.smokeWindowIdentity(windows[0].id) == identity else {
                    return XCTFail("sidebar focus change rebuilt rows or left stale highlighting")
                }
                sidebar.smokeBeginDrag()
                sidebar.updateFocusedWindow(windows[2].id)
                sidebar.smokeEndDrag()
                guard sidebar.smokeSelectedWindowIDs == [windows[2].id], sidebar.smokeRowHoverAppearanceIsValid else {
                    return XCTFail("sidebar row rebuild lost active highlighting")
                }
                for focus in ["missing", nil] {
                    sidebar.updateFocusedWindow(focus)
                    guard sidebar.smokeSelectedWindowIDs.isEmpty, sidebar.smokeRowHoverAppearanceIsValid else {
                        return XCTFail("sidebar retained an inactive window highlight")
                    }
                }
            }
        }
    }

    func testTooltipsShowOnlyForTruncatedTitles() {
        let shortTitleWindow = WindowInfo(id: "smoke-short", appID: "smoke", appName: "Smoke", title: "A",
                                          processID: ProcessInfo.processInfo.processIdentifier)
        for position in SidebarPosition.allCases {
            for displayMode in SidebarItemDisplayMode.allCases {
                sidebar.update(groups: groups,
                               windowsByGroup: [GroupStore.ungroupedID: [windows[0], shortTitleWindow]],
                               alwaysVisible: true, fullscreen: false, position: position,
                               itemDisplayMode: displayMode)
                let expected = [windows[0].id: true, shortTitleWindow.id: displayMode == .icon]
                guard sidebar.smokeTooltipsAreValid(expected: expected) else {
                    return XCTFail("sidebar tooltip mismatch position=\(position) mode=\(displayMode.rawValue)")
                }
            }
        }
    }

    func testGroupVisibilitySettings() {
        let visibilityGroups = groups + [WindowGroup(id: "empty-group", name: "Empty")]
        sidebar.update(groups: visibilityGroups, windowsByGroup: [:],
                       alwaysVisible: true, fullscreen: false)
        guard sidebar.smokeRowOrder == ["g:empty-group"], sidebar.smokeHasCreateGroupButton else {
            return XCTFail("empty Ungrouped was not hidden or custom empty group was lost")
        }
        sidebar.update(groups: visibilityGroups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, showUngrouped: false, showCreateGroup: false)
        guard sidebar.smokeRowOrder == ["g:empty-group"], !sidebar.smokeHasCreateGroupButton,
              abs(sidebar.smokeNaturalContentHeight - 56) < 1 else {
            return XCTFail("group visibility settings did not update rows and height")
        }
        sidebar.smokeBeginDrag()
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false)
        sidebar.smokeEndDrag()
        guard sidebar.smokeRowOrder == ["g:\(GroupStore.ungroupedID)", "w:\(windows[0].id)"],
              sidebar.smokeHasCreateGroupButton else {
            return XCTFail("group visibility update during drag was not applied")
        }
    }

    func testShortcutExpansionAndVisibilityModes() {
        sidebar.update(groups: groups, windowsByGroup: [:], alwaysVisible: true, fullscreen: false,
                       showCreateGroup: false)
        var visibilityFrames = sidebar.smokeSidebarFrames
        sidebar.smokeUpdateHover(pointer: CGPoint(x: visibilityFrames.edge.midX, y: visibilityFrames.edge.midY), now: 0)
        sidebar.setShortcutExpanded(true)
        guard sidebar.smokeIsHidden, sidebar.smokeRowOrder.isEmpty, !sidebar.isShortcutExpanded else {
            return XCTFail("empty sidebar retained a visible or hoverable panel")
        }
        for position in SidebarPosition.allCases {
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: false, position: position)
            guard !sidebar.smokeIsHidden else {
                return XCTFail("sidebar did not reappear when windows returned")
            }
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: true, enabled: false, position: position)
            visibilityFrames = sidebar.smokeSidebarFrames
            sidebar.smokeUpdateHover(pointer: CGPoint(x: visibilityFrames.edge.midX, y: visibilityFrames.edge.midY), now: 0)
            guard sidebar.smokeIsHidden else {
                return XCTFail("disabled sidebar reappeared on hover")
            }
            for mode in SidebarVisibilityMode.allCases {
                for fullscreen in [false, true] {
                    sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                                   alwaysVisible: mode == .always, fullscreen: fullscreen,
                                   enabled: mode != .hidden, position: position)
                    sidebar.setShortcutExpanded(true)
                    sidebar.smokeStopHoverPolling()
                    let outside = CGPoint(x: screen.frame.maxX + 40, y: screen.frame.maxY + 40)
                    sidebar.smokeUpdateHover(pointer: outside, now: 1)
                    sidebar.smokeUpdateHover(pointer: outside, now: 5)
                    guard sidebar.isShortcutExpanded, sidebar.canDismissShortcut, !sidebar.smokeIsHidden else {
                        return XCTFail("shortcut sidebar did not stay visible: \(mode) \(position) \(fullscreen)")
                    }
                    sidebar.setShortcutExpanded(false)
                    guard !sidebar.isShortcutExpanded,
                          sidebar.isVisible == (mode == .always && !fullscreen) else {
                        return XCTFail("shortcut sidebar did not restore its visibility setting")
                    }
                    sidebar.setShortcutExpanded(true)
                    sidebar.smokeStopHoverPolling()
                    let frames = sidebar.smokeSidebarFrames
                    sidebar.smokeUpdateHover(pointer: CGPoint(x: frames.expanded.midX, y: frames.expanded.midY), now: 6)
                    sidebar.smokeUpdateHover(pointer: outside, now: 7)
                    sidebar.smokeUpdateHover(pointer: outside, now: 7.13)
                    guard !sidebar.isShortcutExpanded,
                          sidebar.isVisible == (mode == .always && !fullscreen) else {
                        return XCTFail("shortcut sidebar did not restore visibility after pointer exit")
                    }
                }
            }
        }
    }

    func testVerticalAlignment() {
        for position in [SidebarPosition.left, .right] {
            for fullscreen in [false, true] {
                let alignmentArea = fullscreen ? screen.frame : area
                for count in [1, 200] {
                    for alignment in SidebarVerticalAlignment.allCases {
                        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: Array(windows.prefix(count))],
                                       alwaysVisible: !fullscreen, fullscreen: fullscreen,
                                       verticalAlignment: alignment, position: position)
                        let frames = sidebar.smokeSidebarFrames
                        let expectedY: CGFloat = switch alignment {
                        case .top: alignmentArea.maxY - frames.expanded.height
                        case .center: alignmentArea.midY - frames.expanded.height / 2
                        case .bottom: alignmentArea.minY
                        }
                        guard abs(frames.expanded.minY - expectedY) < 1,
                              abs(frames.edge.minY - expectedY) < 1,
                              frames.expanded.minY >= alignmentArea.minY - 1,
                              frames.expanded.maxY <= alignmentArea.maxY + 1 else {
                            return XCTFail("sidebar vertical alignment mismatch")
                        }
                        sidebar.smokeUpdateHover(pointer: CGPoint(x: frames.edge.midX, y: frames.edge.midY), now: 0)
                        guard !sidebar.smokeIsHidden, abs(sidebar.frame.minY - expectedY) < 1 else {
                            return XCTFail("aligned sidebar did not expand at its edge")
                        }
                        let outside = CGPoint(x: frames.expanded.midX, y: alignmentArea.maxY + 40)
                        sidebar.smokeUpdateHover(pointer: outside, now: 0.1)
                        sidebar.smokeUpdateHover(pointer: outside, now: 0.23)
                    }
                }
            }
        }
    }

    func testWindowMenusAndClose() {
        sidebar.smokeStopHoverPolling()
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: Array(windows.prefix(3))],
                       alwaysVisible: true, fullscreen: false, position: .right)
        guard sidebar.smokeWindowMenusAreValid(windowIDs: Array(windows.prefix(3)).map(\.id)) else {
            return XCTFail("sidebar window menus mismatch")
        }
        sidebar.smokeCloseMenuWindow(windows[1].id)
        sidebar.smokeCloseMenuWindow(windows[2].id)
        sidebar.smokeCloseMenuWindow("missing")
        guard closedWindowIDs == [windows[1].id] else {
            return XCTFail("sidebar close did not target the selected closable window")
        }
    }

    func testContextMenuKeepsSidebarExpanded() {
        let menuGroup = WindowGroup(id: "menu-group", name: "Menu Group")
        for position in SidebarPosition.allCases {
            sidebar.update(groups: [menuGroup], windowsByGroup: [menuGroup.id: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, position: position)
            for group in [false, true] {
                guard sidebar.smokeContextMenuKeepsExpanded(group: group) else {
                    return XCTFail("sidebar context menu lifecycle mismatch: position=\(position.rawValue) group=\(group)")
                }
            }
        }
    }

    func testBadgeRendering() {
        let menuGroup = WindowGroup(id: "menu-group", name: "Menu Group")
        for position in SidebarPosition.allCases {
            sidebar.update(groups: [menuGroup], windowsByGroup: [menuGroup.id: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, position: position)
            assertBadgesRender(position: position)
        }
    }

    private func assertBadgesRender(position: SidebarPosition) {
        for (value, text, diameter) in [
            ("1" as String?, "1", CGFloat(12)),
            ("•", "", CGFloat(7)),
            ("12", "12", CGFloat(15)),
            (nil, "", CGFloat(0)),
            ("•", "", CGFloat(7))
        ] {
            sidebar.smokeApplyBadges(value.map { ["smoke": $0] } ?? [:])
            sidebar.contentView?.layoutSubtreeIfNeeded()
            let valid = value == nil
                ? sidebar.smokeBadgesAreHidden
                : diameter == 7
                    ? sidebar.smokeDotBadgesAreValid
                    : sidebar.smokeBadgesAreValid(text: text, diameter: diameter)
            guard valid else {
                return XCTFail("sidebar badge renderer mismatch position=\(position.rawValue) value=\(value ?? "nil") \(sidebar.smokeBadgeLayoutDescription)")
            }
        }
    }

    func testOverflowScrollsAndShrinks() {
        let oneHeight = singleWindowHeight()
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: windows],
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        guard abs(sidebar.frame.height - area.height) < 1, sidebar.smokeHasOverflow,
              sidebar.smokeVerticalScrollerIsEnabled,
              sidebar.smokeScrollLastWindowIntoView() else {
            return XCTFail("sidebar overflow mismatch: \(sidebar.smokeLayoutDescription) expectedArea=\(area)")
        }

        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        guard abs(sidebar.frame.height - oneHeight) < 1 else {
            return XCTFail("sidebar did not shrink after overflow: one=\(oneHeight) \(sidebar.smokeLayoutDescription)")
        }
    }

    func testHoverRevealsAndCollapses() {
        let oneHeight = singleWindowHeight()
        for position in SidebarPosition.allCases {
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, position: position)
            var frames = sidebar.smokeSidebarFrames
            guard edgeFrame(sidebar.frame, in: area, position: position, width: 8),
                  (position == .bottom || abs(sidebar.frame.height - oneHeight) < 1), sidebar.smokeIsHidden,
                  sidebar.smokeRoundedCornersAreValid else {
                return XCTFail("sidebar collapsed mismatch: \(sidebar.smokeLayoutDescription) expectedArea=\(area)")
            }
            let edgePoint = CGPoint(x: frames.edge.midX, y: frames.edge.midY)
            let insidePoint = CGPoint(x: frames.expanded.midX, y: frames.expanded.midY)
            let outsidePoint = CGPoint(x: frames.expanded.midX, y: frames.expanded.maxY + 40)
            sidebar.smokeUpdateHover(pointer: edgePoint, now: 0)
            let expandedCrossSize: CGFloat = position == .bottom ? 44 : 188
            guard edgeFrame(sidebar.frame, in: area, position: position, width: expandedCrossSize),
                  (position == .bottom || abs(sidebar.frame.height - oneHeight) < 1), !sidebar.smokeIsHidden else {
                return XCTFail("sidebar hover mismatch: \(sidebar.smokeLayoutDescription) expectedArea=\(area)")
            }
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, position: position)
            sidebar.smokeUpdateHover(pointer: insidePoint, now: 0.05)
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 0.1)
            guard edgeFrame(sidebar.frame, in: area, position: position, width: expandedCrossSize),
                  !sidebar.smokeIsHidden else {
                return XCTFail("sidebar collapsed before delay: \(sidebar.smokeLayoutDescription)")
            }
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 0.23)
            guard edgeFrame(sidebar.frame, in: area, position: position, width: 8),
                  sidebar.smokeIsHidden else {
                return XCTFail("sidebar did not collapse after leave: \(sidebar.smokeLayoutDescription)")
            }
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, position: position)
            guard sidebar.smokeIsHidden else {
                return XCTFail("sidebar refresh exposed collapsed panel: \(sidebar.smokeLayoutDescription)")
            }

            sidebar.smokeUpdateHover(pointer: edgePoint, now: 0.3)
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 0.4, dragging: true)
            guard edgeFrame(sidebar.frame, in: area, position: position, width: expandedCrossSize),
                  !sidebar.smokeIsHidden else {
                return XCTFail("sidebar collapsed during drag: \(sidebar.smokeLayoutDescription)")
            }
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 0.5, dragging: false)
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 0.63)
            guard edgeFrame(sidebar.frame, in: area, position: position, width: 8),
                  sidebar.smokeIsHidden else {
                return XCTFail("sidebar did not collapse after drag: \(sidebar.smokeLayoutDescription)")
            }

            let screenSide = screen.frame
            let farSidePoints = position == .bottom
                ? [CGPoint(x: screenSide.minX, y: frames.edge.midY), CGPoint(x: screenSide.maxX, y: frames.edge.midY)]
                : [CGPoint(x: frames.edge.midX, y: screenSide.minY), CGPoint(x: frames.edge.midX, y: screenSide.maxY)]
            for (index, farPoint) in farSidePoints.enumerated() {
                let start = 0.7 + Double(index)
                guard !frames.expanded.contains(farPoint) else {
                    return XCTFail("far side point \(farPoint) is inside the panel \(frames.expanded)")
                }
                sidebar.smokeUpdateHover(pointer: farPoint, now: start)
                guard edgeFrame(sidebar.frame, in: area, position: position, width: expandedCrossSize),
                      !sidebar.smokeIsHidden else {
                    return XCTFail("sidebar did not open from far side \(farPoint): \(sidebar.smokeLayoutDescription)")
                }
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: start + 0.1)
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: start + 0.23)
                guard sidebar.smokeIsHidden else {
                    return XCTFail("sidebar did not collapse after far side hover: \(sidebar.smokeLayoutDescription)")
                }
            }

            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: true, position: position)
            frames = sidebar.smokeSidebarFrames
            guard edgeFrame(sidebar.frame, in: screen.frame, position: position, width: 8),
                  sidebar.smokeIsHidden else {
                return XCTFail("sidebar fullscreen collapse mismatch: \(sidebar.smokeLayoutDescription) expectedArea=\(screen.frame)")
            }
            sidebar.smokeUpdateHover(pointer: CGPoint(x: frames.edge.midX, y: frames.edge.midY), now: 1)
            guard edgeFrame(sidebar.frame, in: screen.frame, position: position, width: expandedCrossSize),
                  !sidebar.smokeIsHidden else {
                return XCTFail("sidebar fullscreen hover mismatch: \(sidebar.smokeLayoutDescription) expectedArea=\(screen.frame)")
            }
            let fullscreenOutside = CGPoint(x: frames.expanded.midX, y: frames.expanded.maxY + 40)
            sidebar.smokeUpdateHover(pointer: fullscreenOutside, now: 1.1)
            sidebar.smokeUpdateHover(pointer: fullscreenOutside, now: 1.23)
            guard edgeFrame(sidebar.frame, in: screen.frame, position: position, width: 8),
                  sidebar.smokeIsHidden else {
                return XCTFail("sidebar fullscreen did not collapse after leave: \(sidebar.smokeLayoutDescription)")
            }
        }
    }

    func testAnimatedReveal() {
        sidebar.smokeSetAnimatesVisibility(true)
        for reduceMotion in [false, true] {
            sidebar.smokeSetReduceMotion(reduceMotion)
            for position in SidebarPosition.allCases {
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                               alwaysVisible: false, fullscreen: false, position: position)
                let frames = sidebar.smokeSidebarFrames
                let edgePoint = CGPoint(x: frames.edge.midX, y: frames.edge.midY)
                let outsidePoint = CGPoint(x: frames.expanded.midX, y: frames.expanded.maxY + 40)
                let label = "position=\(position) reduceMotion=\(reduceMotion)"
                func revealFailure(_ message: String) {
                    XCTFail("\(message): \(label) \(sidebar.smokeRevealDescription)")
                }
                guard sidebar.smokeIsHidden else { return revealFailure("animated sidebar started visible") }
                sidebar.smokeUpdateHover(pointer: edgePoint, now: 10)
                guard sidebar.smokeRevealIsAnimating, sidebar.smokeRevealIsConsistent(progress: 0) else {
                    return revealFailure("sidebar reveal did not start from the edge")
                }
                sidebar.smokeAdvanceReveal(by: SidebarReveal.duration / 2)
                guard sidebar.smokeRevealIsConsistent(progress: 0.5) else {
                    return revealFailure("sidebar reveal midpoint mismatch")
                }
                sidebar.smokeAdvanceReveal(by: SidebarReveal.duration)
                guard sidebar.smokeRevealIsConsistent(progress: 1), !sidebar.smokeRevealIsAnimating else {
                    return revealFailure("sidebar reveal did not finish expanded")
                }
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: 11)
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: 11.13)
                guard sidebar.smokeRevealIsAnimating, sidebar.smokeRevealIsConsistent(progress: 1) else {
                    return revealFailure("sidebar hide did not animate")
                }
                sidebar.smokeAdvanceReveal(by: SidebarReveal.duration / 2)
                guard sidebar.smokeRevealIsConsistent(progress: 0.5) else {
                    return revealFailure("sidebar hide midpoint mismatch")
                }
                sidebar.smokeUpdateHover(pointer: edgePoint, now: 11.2)
                sidebar.smokeAdvanceReveal(by: SidebarReveal.duration / 4)
                guard sidebar.smokeRevealIsConsistent(progress: 0.75) else {
                    return revealFailure("sidebar did not reverse a hide in progress")
                }
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: 12)
                sidebar.smokeUpdateHover(pointer: outsidePoint, now: 12.13)
                RunLoop.main.run(until: Date().addingTimeInterval(SidebarReveal.duration * 2))
                guard sidebar.smokeIsHidden, !sidebar.smokeRevealIsAnimating, sidebar.alphaValue == 1,
                      edgeFrame(sidebar.frame, in: area, position: position, width: 8) else {
                    return revealFailure("timer-driven sidebar hide did not finish")
                }
            }
        }
        sidebar.smokeSetReduceMotion(nil)
        sidebar.smokeSetAnimatesVisibility(false)
    }

    func testResizeByDraggingInnerEdge() {
        let widthRange = CGFloat(AppSettings.sidebarWidthRange.lowerBound)...CGFloat(AppSettings.sidebarWidthRange.upperBound)
        for position in [SidebarPosition.left, .right] {
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, sidebarWidth: 188, position: position)
            let frames = sidebar.smokeSidebarFrames
            let outsidePoint = CGPoint(x: frames.expanded.midX, y: frames.expanded.maxY + 40)
            sidebar.smokeUpdateHover(pointer: CGPoint(x: frames.edge.midX, y: frames.edge.midY), now: 20)
            guard !sidebar.smokeIsHidden, sidebar.smokeResizeHandleIsValid else {
                return XCTFail("sidebar resize handle missing at inner edge: \(position) \(sidebar.smokeLayoutDescription)")
            }
            let grow: CGFloat = position == .right ? -1 : 1
            let innerX = position == .right ? sidebar.frame.minX : sidebar.frame.maxX
            resizedWidths = []
            sidebar.smokeBeginResize(at: innerX)
            func resized(to width: CGFloat) -> Bool {
                sidebar.contentView?.layoutSubtreeIfNeeded()
                return edgeFrame(sidebar.frame, in: area, position: position, width: width)
                    && abs(sidebar.smokeEffectWidth - width) < 0.5 && sidebar.smokeResizeHandleIsValid
                    && sidebar.smokeWindowItemsAreValid(showsTitle: true, maximumWidth: width)
            }
            for (offset, expected) in [(50, 238), (-50, 138), (5000, widthRange.upperBound),
                                       (-5000, widthRange.lowerBound), (50.4, 238)] as [(CGFloat, CGFloat)] {
                sidebar.smokeResize(to: innerX + grow * offset)
                guard resized(to: expected) else {
                    return XCTFail("sidebar resize to \(expected) mismatch: \(position) \(sidebar.smokeLayoutDescription)")
                }
            }
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 21)
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 22)
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: false, fullscreen: false, sidebarWidth: 188, position: position)
            guard !sidebar.smokeIsHidden, resized(to: 238), resizedWidths.isEmpty else {
                return XCTFail("sidebar resize was interrupted by hover or settings: \(position) \(sidebar.smokeLayoutDescription)")
            }
            sidebar.smokeEndResize()
            sidebar.smokeEndResize()
            guard resizedWidths == [238] else {
                return XCTFail("sidebar resize reported \(resizedWidths) instead of [238]")
            }
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 23)
            sidebar.smokeUpdateHover(pointer: outsidePoint, now: 23.13)
            guard sidebar.smokeIsHidden else {
                return XCTFail("sidebar did not collapse after resize ended: \(position)")
            }
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: false, sidebarWidth: 238, position: position)
            sidebar.smokeBeginResize(at: innerX)
            sidebar.smokeEndResize()
            guard resized(to: 238), resizedWidths == [238] else {
                return XCTFail("sidebar click on resize handle changed width: \(position)")
            }
        }
        for (position, mode) in [(SidebarPosition.bottom, SidebarItemDisplayMode.iconAndTitle), (.left, .icon), (.right, .icon)] {
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: false, sidebarWidth: 188, position: position,
                           itemDisplayMode: mode)
            let before = sidebar.frame
            resizedWidths = []
            sidebar.smokeBeginResize(at: before.minX)
            sidebar.smokeResize(to: before.minX - 80)
            sidebar.smokeEndResize()
            guard sidebar.smokeResizeHandleIsValid, sidebar.frame.approximatelyEquals(before), resizedWidths.isEmpty else {
                return XCTFail("sidebar resized where it should not: \(position) \(mode.rawValue)")
            }
        }
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, position: .right)
    }

    func testSidebarWidthSetting() {
        for position in [SidebarPosition.left, .right] {
            for width in [CGFloat(AppSettings.sidebarWidthRange.lowerBound), 188,
                          CGFloat(AppSettings.sidebarWidthRange.upperBound)] {
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                               alwaysVisible: true, fullscreen: false, sidebarWidth: width, position: position)
                let rowIdentity = sidebar.smokeWindowIdentity(windows[0].id)
                let narrower = max(CGFloat(AppSettings.sidebarWidthRange.lowerBound), width - 10)
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                               alwaysVisible: true, fullscreen: false, sidebarWidth: narrower, position: position)
                guard edgeFrame(sidebar.frame, in: area, position: position, width: narrower),
                      sidebar.smokePositionLayoutIsValid,
                      sidebar.smokeWindowWidthIs(narrower - 8),
                      sidebar.smokeWindowIdentity(windows[0].id) == rowIdentity else {
                    return XCTFail("sidebar live resize mismatch: \(sidebar.smokeLayoutDescription)")
                }
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                               alwaysVisible: false, fullscreen: true, sidebarWidth: width, position: position)
                let frames = sidebar.smokeSidebarFrames
                sidebar.smokeUpdateHover(pointer: CGPoint(x: frames.edge.midX, y: frames.edge.midY), now: 2)
                guard edgeFrame(sidebar.frame, in: screen.frame, position: position, width: width) else {
                    return XCTFail("custom sidebar width was lost on fullscreen hover")
                }
                sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                               alwaysVisible: true, fullscreen: false, sidebarWidth: width, position: position,
                               itemDisplayMode: .icon)
                guard abs(sidebar.frame.width - 44) < 1 else {
                    return XCTFail("sidebar width affected icons-only layout")
                }
            }
        }
        sidebar.smokeBeginDrag()
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false,
                       sidebarWidth: CGFloat(AppSettings.sidebarWidthRange.upperBound))
        sidebar.smokeEndDrag()
        guard abs(sidebar.frame.width - CGFloat(AppSettings.sidebarWidthRange.upperBound)) < 1 else {
            return XCTFail("sidebar width update during drag was lost")
        }
    }

    func testBottomLayout() {
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, position: .bottom,
                       itemDisplayMode: .icon)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.smokePositionLayoutIsValid, sidebar.smokeTitleVisibilityIsValid,
              sidebar.smokeWindowMenusAreValid(windowIDs: [windows[0].id]),
              sidebar.smokeWindowItemsAreValid(showsTitle: false, maximumWidth: 32),
              sidebar.smokeBottomItemsFit(windowCount: 1, maximumWindowWidth: 32),
              sidebar.smokeWindowWidthIs(32),
              sidebar.frame.width < area.width,
              abs(sidebar.frame.midX - area.midX) < 1,
              sidebar.frame.minX >= area.minX, sidebar.frame.maxX <= area.maxX,
              sidebar.frame.minY >= area.minY, sidebar.frame.maxY <= area.maxY else {
            return XCTFail("sidebar bottom icon layout mismatch: \(sidebar.smokeLayoutDescription)")
        }
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                       alwaysVisible: true, fullscreen: false, position: .bottom,
                       itemDisplayMode: .iconAndTitle)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        guard sidebar.smokeBottomItemsFit(windowCount: 1, maximumWindowWidth: 188),
              sidebar.smokeWindowMenusAreValid(windowIDs: [windows[0].id]),
              sidebar.smokeWindowWidthIs(188), sidebar.frame.width < area.width,
              abs(sidebar.frame.midX - area.midX) < 1 else {
            return XCTFail("sidebar bottom compact title layout mismatch: \(sidebar.smokeLayoutDescription)")
        }
        let originalBottomFrame = sidebar.frame
        for width in [CGFloat(AppSettings.sidebarWidthRange.lowerBound),
                      CGFloat(AppSettings.sidebarWidthRange.upperBound)] {
            sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: [windows[0]]],
                           alwaysVisible: true, fullscreen: false, sidebarWidth: width, position: .bottom)
            guard sidebar.frame.approximatelyEquals(originalBottomFrame), sidebar.smokeWindowWidthIs(188) else {
                return XCTFail("sidebar width affected bottom layout")
            }
        }
        let bottomGroups = [WindowGroup(id: GroupStore.ungroupedID, name: "未分组")] + (1...11).map {
            WindowGroup(id: "bottom-group-\($0)", name: "Bottom Group \($0)")
        }
        var bottomWindows: [String: [WindowInfo]] = [:]
        for (index, window) in windows.enumerated() {
            bottomWindows[bottomGroups[index % 3].id, default: []].append(window)
        }
        for mode in SidebarItemDisplayMode.allCases {
            sidebar.update(groups: bottomGroups, windowsByGroup: bottomWindows,
                           alwaysVisible: true, fullscreen: false, position: .bottom,
                           itemDisplayMode: mode)
            sidebar.contentView?.layoutSubtreeIfNeeded()
            let showsTitle = mode == .iconAndTitle
            let maximumWidth: CGFloat = showsTitle ? 188 : 32
            guard sidebar.smokePositionLayoutIsValid, sidebar.smokeTitleVisibilityIsValid,
                  sidebar.smokeWindowItemsAreValid(showsTitle: showsTitle,
                                                   maximumWidth: maximumWidth),
                  sidebar.smokeBottomItemsFit(windowCount: windows.count,
                                              maximumWindowWidth: maximumWidth),
                  !sidebar.smokeHasOverflow,
                  abs(sidebar.frame.width - area.width) < 1,
                  abs(sidebar.frame.midX - area.midX) < 1,
                  sidebar.frame.minX >= area.minX, sidebar.frame.maxX <= area.maxX,
                  sidebar.frame.minY >= area.minY, sidebar.frame.maxY <= area.maxY else {
                return XCTFail("sidebar bottom \(mode.rawValue) layout mismatch: \(sidebar.smokeLayoutDescription)")
            }
        }
    }

    func testDragPreviewAndCommit() {
        let originalWindows = [
            GroupStore.ungroupedID: [windows[0]],
            firstGroupID: [windows[1], windows[2]],
            secondGroupID: [windows[3]]
        ]
        sidebar.update(groups: dragGroups, windowsByGroup: originalWindows,
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.contentView?.layoutSubtreeIfNeeded()
        let originalOrder = sidebar.smokeRowOrder
        let sourceIdentity = sidebar.smokeWindowIdentity(windows[1].id)
        sidebar.smokeBeginDrag()
        sidebar.smokePreviewWindow(windows[1].id, groupID: secondGroupID,
                                   beforeWindowID: windows[3].id)
        let previewOrder = sidebar.smokeRowOrder
        let selfHitWasStable = sidebar.smokeWindowSelfHitKeepsPreview(
            windows[1].id, groupID: secondGroupID
        )
        sidebar.smokePreviewWindow(windows[1].id, groupID: secondGroupID,
                                   beforeWindowID: windows[3].id)
        guard previewOrder != originalOrder, sidebar.smokeRowOrder == previewOrder,
              selfHitWasStable,
              sidebar.smokeWindowIdentity(windows[1].id) == sourceIdentity,
              windowMoves.isEmpty, groupMoves.isEmpty else {
            return XCTFail("sidebar live preview changed identity or invoked callbacks")
        }
        sidebar.smokeDestinationExited()
        guard sidebar.smokeRowOrder == originalOrder, sidebar.smokeIsDragging,
              sidebar.smokeWindowIdentity(windows[1].id) == sourceIdentity else {
            return XCTFail("sidebar destination exit ended source drag or replaced its view")
        }
        sidebar.smokePreviewWindow(windows[1].id, groupID: secondGroupID,
                                   beforeWindowID: windows[3].id)
        sidebar.smokeCommitPreview()
        guard windowMoves.count == 1,
              windowMoves[0].0 == windows[1].id,
              windowMoves[0].1 == secondGroupID,
              windowMoves[0].2 == windows[3].id else {
            return XCTFail("sidebar window drop callback mismatch: \(windowMoves)")
        }
        let refreshedWindows = [
            GroupStore.ungroupedID: [windows[0]],
            firstGroupID: [windows[2]],
            secondGroupID: [windows[1], windows[3]]
        ]
        sidebar.update(groups: dragGroups, windowsByGroup: refreshedWindows,
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.smokeEndDrag()
        guard sidebar.smokeRowOrder == [
            "g:\(GroupStore.ungroupedID)", "w:\(windows[0].id)",
            "g:\(firstGroupID)", "w:\(windows[2].id)",
            "g:\(secondGroupID)", "w:\(windows[1].id)", "w:\(windows[3].id)"
        ] else {
            return XCTFail("sidebar pending refresh was not applied after drop")
        }
        sidebar.smokeBeginDrag()
        sidebar.smokePreviewGroup(secondGroupID, beforeGroupID: firstGroupID)
        let groupPreviewOrder = sidebar.smokeRowOrder
        sidebar.smokeCommitPreview()
        sidebar.smokeEndDrag()
        let secondIndex = groupPreviewOrder.firstIndex(of: "g:\(secondGroupID)") ?? .max
        let firstIndex = groupPreviewOrder.firstIndex(of: "g:\(firstGroupID)") ?? -1
        guard groupPreviewOrder.first == "g:\(GroupStore.ungroupedID)",
              secondIndex < firstIndex,
              groupMoves.count == 1, groupMoves[0].0 == secondGroupID,
              groupMoves[0].1 == firstGroupID else {
            return XCTFail("sidebar group preview or callback mismatch")
        }
        sidebar.smokeBeginDrag()
        sidebar.smokeDestinationEntered()
        sidebar.smokeEndDrag()
        guard !sidebar.smokeIsDragging else {
            return XCTFail("sidebar remained in dragging state after source cancellation")
        }
    }

    func testStationaryDropsAreStable() {
        for position in SidebarPosition.allCases {
            sidebar.update(groups: dragGroups, windowsByGroup: coordinateWindows,
                           alwaysVisible: true, fullscreen: false, position: position)
            let coordinates = sidebar.smokeRowCoordinates
            sidebar.smokeBeginDrag()
            sidebar.smokePreviewWindow(windows[4].id, at: coordinates[9])
            guard sidebar.smokeRowOrder == [
                "g:\(GroupStore.ungroupedID)", "w:\(windows[5].id)",
                "g:\(firstGroupID)", "w:\(windows[4].id)", "w:\(windows[6].id)", "w:\(windows[7].id)",
                "g:\(secondGroupID)", "w:\(windows[8].id)", "w:\(windows[9].id)"
            ] else {
                return XCTFail("sidebar group header did not insert at the start: \(sidebar.smokeRowOrder)")
            }
            sidebar.smokeEndDrag()
            for source in windows[4...9] {
                sidebar.smokeBeginDrag()
                for coordinate in coordinates + coordinates.reversed() {
                    sidebar.smokePreviewWindow(source.id, at: coordinate)
                    let order = sidebar.smokeRowOrder
                    for _ in 0..<4 {
                        sidebar.smokePreviewWindow(source.id, at: coordinate)
                        guard sidebar.smokeRowOrder == order else {
                            return XCTFail("sidebar stationary drop moved at \(position) \(coordinate): \(order) -> \(sidebar.smokeRowOrder)")
                        }
                    }
                }
                sidebar.smokeEndDrag()
            }
        }
    }

    func testUntitledUngroupedDrops() {
        for position in SidebarPosition.allCases {
            sidebar.update(groups: dragGroups, windowsByGroup: coordinateWindows,
                           alwaysVisible: true, fullscreen: false, position: position)
            let titledHeight = sidebar.smokeNaturalContentHeight
            sidebar.update(groups: dragGroups, windowsByGroup: coordinateWindows,
                           alwaysVisible: true, fullscreen: false, showUngroupedTitle: false, position: position)
            sidebar.contentView?.layoutSubtreeIfNeeded()
            guard sidebar.smokeRowOrder.first == "g:\(GroupStore.ungroupedID)",
                  sidebar.smokeVisibleRowOrder == [
                      "w:\(windows[4].id)", "w:\(windows[5].id)",
                      "g:\(firstGroupID)", "w:\(windows[6].id)", "w:\(windows[7].id)",
                      "g:\(secondGroupID)", "w:\(windows[8].id)", "w:\(windows[9].id)"
                  ],
                  sidebar.smokeFirstVisibleRowStartsAtEdge,
                  position == .bottom || abs(titledHeight - sidebar.smokeNaturalContentHeight - 32) < 1 else {
                return XCTFail("sidebar Ungrouped title was not hidden at \(position): \(sidebar.smokeVisibleRowOrder) \(sidebar.smokeLayoutDescription)")
            }
            let coordinates = sidebar.smokeRowCoordinates
            sidebar.smokeBeginDrag()
            sidebar.smokePreviewWindow(windows[6].id, at: coordinates[0])
            guard sidebar.smokeRowOrder == [
                "g:\(GroupStore.ungroupedID)", "w:\(windows[6].id)", "w:\(windows[4].id)", "w:\(windows[5].id)",
                "g:\(firstGroupID)", "w:\(windows[7].id)",
                "g:\(secondGroupID)", "w:\(windows[8].id)", "w:\(windows[9].id)"
            ] else {
                return XCTFail("sidebar drop above first untitled Ungrouped window missed Ungrouped: \(sidebar.smokeRowOrder)")
            }
            sidebar.smokeEndDrag()
            for source in windows[4...9] {
                sidebar.smokeBeginDrag()
                for coordinate in coordinates + coordinates.reversed() {
                    sidebar.smokePreviewWindow(source.id, at: coordinate)
                    let order = sidebar.smokeRowOrder
                    guard order.first == "g:\(GroupStore.ungroupedID)" else {
                        return XCTFail("sidebar drop moved a window above untitled Ungrouped: \(order)")
                    }
                    for _ in 0..<4 {
                        sidebar.smokePreviewWindow(source.id, at: coordinate)
                        guard sidebar.smokeRowOrder == order else {
                            return XCTFail("sidebar untitled Ungrouped stationary drop moved at \(position) \(coordinate): \(order) -> \(sidebar.smokeRowOrder)")
                        }
                    }
                }
                sidebar.smokeEndDrag()
            }
        }
        sidebar.update(groups: dragGroups, windowsByGroup: coordinateWindows,
                       alwaysVisible: true, fullscreen: false, showUngrouped: false,
                       showUngroupedTitle: false, position: .right)
        guard sidebar.smokeRowOrder == [
            "g:\(firstGroupID)", "w:\(windows[6].id)", "w:\(windows[7].id)",
            "g:\(secondGroupID)", "w:\(windows[8].id)", "w:\(windows[9].id)"
        ] else {
            return XCTFail("hidden Ungrouped title setting changed hidden Ungrouped rows: \(sidebar.smokeRowOrder)")
        }
    }

    func testPinnedPreviewMatchesCommittedOrder() {
        let pinStore = GroupStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("groups.json"))
        let pinWindows = Array(windows.prefix(4))
        pinStore.reconcile(pinWindows)
        pinStore.togglePin(id: windows[0].id)
        pinStore.togglePin(id: windows[1].id)
        sidebar.update(groups: groups, windowsByGroup: [GroupStore.ungroupedID: pinWindows],
                       alwaysVisible: true, fullscreen: false, position: .right)
        sidebar.smokeBeginDrag()
        sidebar.smokePreviewWindow(windows[3].id, at: sidebar.smokeRowCoordinates[5])
        let pinnedPreviewIDs = sidebar.smokeRowOrder.compactMap { $0.hasPrefix("w:") ? String($0.dropFirst(2)) : nil }
        pinStore.moveWindow(id: windows[3].id, to: GroupStore.ungroupedID, before: windows[1].id,
                            visibleOrderByGroup: [GroupStore.ungroupedID: pinnedPreviewIDs])
        guard pinnedPreviewIDs == pinStore.windows(in: GroupStore.ungroupedID).map(\.id),
              pinnedPreviewIDs == [windows[0].id, windows[3].id, windows[1].id, windows[2].id],
              pinStore.pinPosition(id: windows[0].id) == 0,
              pinStore.pinPosition(id: windows[1].id) == 2 else {
            return XCTFail("sidebar pinned preview differs from committed order: \(pinnedPreviewIDs)")
        }
        sidebar.smokeEndDrag()
    }

    private func edgeFrame(_ frame: NSRect, in area: NSRect,
                                  position: SidebarPosition, width: CGFloat) -> Bool {
        let centered = abs(frame.midY - area.midY) < 1
        switch position {
        case .left: return centered && abs(frame.minX - area.minX) < 1 && abs(frame.width - width) < 1
        case .right: return centered && abs(frame.maxX - area.maxX) < 1 && abs(frame.width - width) < 1
        case .bottom:
            return abs(frame.midX - area.midX) < 1 && abs(frame.minY - area.minY) < 1
                && abs(frame.height - width) < 1
        }
    }

    private func naturalHeightIsValid(_ sidebar: SidebarPanel, in area: NSRect) -> Bool {
        abs(sidebar.frame.height - min(sidebar.smokeNaturalContentHeight, area.height)) < 1
            && abs(sidebar.frame.midY - area.midY) < 1
    }
}
