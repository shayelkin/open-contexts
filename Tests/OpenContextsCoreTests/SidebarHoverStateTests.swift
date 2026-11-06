import CoreGraphics
import XCTest
@testable import OpenContextsCore

final class SidebarHoverStateTests: XCTestCase {
    private let edge = CGRect(x: 992, y: 300, width: 8, height: 200)
    private let expanded = CGRect(x: 740, y: 300, width: 260, height: 200)

    func testShortcutExpansionReturnsToHoverAfterPointerEnters() {
        var state = SidebarHoverState()
        let outside = CGPoint(x: 700, y: 400)
        let inside = CGPoint(x: 900, y: 400)
        state.setShortcutExpanded(true)
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 0))
        XCTAssertFalse(state.update(pointer: inside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 1))
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 2))
        XCTAssertTrue(state.isShortcutExpanded)
        XCTAssertFalse(state.update(pointer: inside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 2.05))
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 3))
        XCTAssertTrue(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                   dragging: false, now: 3.13))
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isShortcutExpanded)
        state.setShortcutExpanded(true)
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 10))
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 20))
        XCTAssertTrue(state.isShortcutExpanded)
    }

    func testShortcutHoverExitWaitsForMenuOrDragToFinish() {
        for menuOpen in [false, true] {
            var state = SidebarHoverState()
            let outside = CGPoint(x: 700, y: 400)
            state.setShortcutExpanded(true)
            state.update(pointer: CGPoint(x: 900, y: 400), edgeFrame: edge,
                         expandedFrame: expanded, dragging: false, now: 0)
            for now in [1.0, 5] {
                XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                            dragging: !menuOpen, menuOpen: menuOpen, now: now))
                XCTAssertTrue(state.isShortcutExpanded)
            }
            XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                        dragging: false, now: 6))
            XCTAssertTrue(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                       dragging: false, now: 6.13))
            XCTAssertFalse(state.isExpanded)
            XCTAssertFalse(state.isShortcutExpanded)
        }
    }

    func testShortcutKeepsExpandedAndDismissalWaitsForPointerExit() {
        var state = SidebarHoverState()
        let outside = CGPoint(x: 700, y: 400)
        let inside = CGPoint(x: 900, y: 400)
        state.setShortcutExpanded(true)
        for now in [0.0, 1, 5] {
            XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                        dragging: false, now: now))
            XCTAssertTrue(state.isExpanded)
            XCTAssertTrue(state.isShortcutExpanded)
        }
        state.setShortcutExpanded(false)
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isShortcutExpanded)
        for pointer in [inside, CGPoint(x: 996, y: 400), outside] {
            XCTAssertFalse(state.update(pointer: pointer, edgeFrame: edge, expandedFrame: expanded,
                                        dragging: false, now: 6))
            XCTAssertFalse(state.isExpanded)
        }
        XCTAssertTrue(state.update(pointer: CGPoint(x: 996, y: 400), edgeFrame: edge,
                                   expandedFrame: expanded, dragging: false, now: 7))
        XCTAssertTrue(state.isExpanded)
    }

    func testEdgeExpansionStaysOpenAcrossResizeEventsAndDelayedExit() {
        var state = SidebarHoverState()
        XCTAssertTrue(state.update(pointer: CGPoint(x: 996, y: 400), edgeFrame: edge,
                                   expandedFrame: expanded, dragging: false, now: 0))
        XCTAssertTrue(state.isExpanded)
        XCTAssertFalse(state.update(pointer: CGPoint(x: 900, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 0.01))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 900, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 1))

        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 2))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 900, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 2.05))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 3))
        XCTAssertTrue(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                   expandedFrame: expanded, dragging: false, now: 3.12))
        XCTAssertFalse(state.isExpanded)
    }

    func testReentryCancelsCollapseAndDraggingKeepsExpanded() {
        var state = SidebarHoverState(isExpanded: true)
        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 0))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 900, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 0.1))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 1))
        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: true, now: 2))
        XCTAssertTrue(state.isExpanded)
        XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                    expandedFrame: expanded, dragging: false, now: 3))
        XCTAssertTrue(state.update(pointer: CGPoint(x: 700, y: 400), edgeFrame: edge,
                                   expandedFrame: expanded, dragging: false, now: 3.12))
        XCTAssertFalse(state.isExpanded)
    }

    func testEdgeTriggerSpansWholeScreenSideWithoutWideningTheStrip() {
        var generator = SystemRandomNumberGenerator()
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                       CGRect(x: 1440, y: -400, width: 1080, height: 1920)]
        for _ in 0..<1000 {
            let screen = screens.randomElement(using: &generator)!
            let vertical = Bool.random(using: &generator)
            let length = CGFloat.random(in: 52...(vertical ? screen.height : screen.width), using: &generator)
            let offset = CGFloat.random(in: 0...((vertical ? screen.height : screen.width) - length), using: &generator)
            let edge = vertical
                ? CGRect(x: Bool.random(using: &generator) ? screen.minX : screen.maxX - 8,
                         y: screen.minY + offset, width: 8, height: length)
                : CGRect(x: screen.minX + offset, y: screen.minY, width: length, height: 8)
            let trigger = SidebarHoverState.edgeTriggerFrame(edge: edge, screen: screen, vertical: vertical)
            XCTAssertTrue(trigger.contains(edge))
            let along = CGFloat.random(in: 0...1, using: &generator)
            let across = CGFloat.random(in: 0..<1, using: &generator)
            let inside = vertical
                ? CGPoint(x: edge.minX + edge.width * across, y: screen.minY + screen.height * along)
                : CGPoint(x: screen.minX + screen.width * along, y: edge.minY + edge.height * across)
            XCTAssertTrue(trigger.contains(inside), "\(inside) not in \(trigger)")
            let distance = CGFloat.random(in: 0...400, using: &generator)
            let besides = vertical
                ? [CGPoint(x: edge.minX - 0.01 - distance, y: inside.y), CGPoint(x: edge.maxX + distance, y: inside.y)]
                : [CGPoint(x: inside.x, y: edge.minY - 0.01 - distance), CGPoint(x: inside.x, y: edge.maxY + distance)]
            besides.forEach { XCTAssertFalse(trigger.contains($0), "\($0) in \(trigger)") }
            let beyond = CGFloat.random(in: 1...400, using: &generator)
            let pastEnds = vertical
                ? [CGPoint(x: inside.x, y: screen.minY - beyond), CGPoint(x: inside.x, y: screen.maxY + beyond)]
                : [CGPoint(x: screen.minX - beyond, y: inside.y), CGPoint(x: screen.maxX + beyond, y: inside.y)]
            pastEnds.forEach { XCTAssertFalse(trigger.contains($0), "\($0) in \(trigger)") }
        }
    }

    func testPointerAnywhereAlongTheSideExpandsAndKeepsExpanded() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let trigger = SidebarHoverState.edgeTriggerFrame(edge: edge, screen: screen, vertical: true)
        for y in stride(from: screen.minY, through: screen.maxY, by: 25) {
            var state = SidebarHoverState()
            XCTAssertTrue(state.update(pointer: CGPoint(x: 999, y: y), edgeFrame: trigger,
                                       expandedFrame: expanded, dragging: false, now: 0))
            XCTAssertFalse(state.update(pointer: CGPoint(x: 999, y: y), edgeFrame: trigger,
                                        expandedFrame: expanded, dragging: false, now: 5))
            XCTAssertTrue(state.isExpanded)
            XCTAssertFalse(state.update(pointer: CGPoint(x: 700, y: y), edgeFrame: trigger,
                                        expandedFrame: expanded, dragging: false, now: 6))
            XCTAssertTrue(state.update(pointer: CGPoint(x: 700, y: y), edgeFrame: trigger,
                                       expandedFrame: expanded, dragging: false, now: 6.12))
            XCTAssertFalse(state.isExpanded)
        }
    }

    func testContextMenuKeepsExpandedAndRestartsCollapseDelayAfterClosing() {
        var state = SidebarHoverState(isExpanded: true)
        let outside = CGPoint(x: 700, y: 400)
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 0))
        for now in [0.2, 1, 5] {
            XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                        dragging: false, menuOpen: true, now: now))
            XCTAssertTrue(state.isExpanded)
        }
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 6))
        XCTAssertFalse(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                    dragging: false, now: 6.1))
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.update(pointer: outside, edgeFrame: edge, expandedFrame: expanded,
                                   dragging: false, now: 6.13))
        XCTAssertFalse(state.isExpanded)
    }

    func testCollapseDeadlineIsWhenARestingPointerCollapsesTheSidebar() {
        var random = SystemRandomNumberGenerator()
        let points = [CGPoint(x: 700, y: 400), CGPoint(x: 900, y: 400), CGPoint(x: 995, y: 400), CGPoint(x: 995, y: 50)]
        for _ in 0..<500 {
            var state = SidebarHoverState()
            var now = 0.0
            for _ in 0..<30 {
                now += Double.random(in: 0...0.3, using: &random)
                let menuOpen = Int.random(in: 0..<10, using: &random) == 0
                if Int.random(in: 0..<15, using: &random) == 0 { state.setShortcutExpanded(Bool.random(using: &random)) }
                state.update(pointer: points.randomElement(using: &random)!, edgeFrame: edge, expandedFrame: expanded,
                             dragging: false, menuOpen: menuOpen, now: now)
                guard let deadline = state.collapseDeadline() else { continue }
                XCTAssertTrue(state.isExpanded)
                var resting = state
                resting.update(pointer: points[0], edgeFrame: edge, expandedFrame: expanded, dragging: false,
                               now: deadline + 0.001)
                XCTAssertFalse(resting.isExpanded, "a pointer resting outside past the deadline kept it expanded")
                XCTAssertNil(resting.collapseDeadline())
                var early = state
                early.update(pointer: points[0], edgeFrame: edge, expandedFrame: expanded, dragging: false,
                             now: deadline - 0.01)
                XCTAssertTrue(early.isExpanded, "the sidebar collapsed before its deadline")
            }
        }
        var idle = SidebarHoverState()
        XCTAssertNil(idle.collapseDeadline())
        idle.update(pointer: points[0], edgeFrame: edge, expandedFrame: expanded, dragging: false, now: 1)
        XCTAssertNil(idle.collapseDeadline(), "a collapsed sidebar reported a pending collapse")
    }
}
