import AppKit
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

@MainActor
final class SwitcherPanelTests: XCTestCase {
    private var switcher: SwitcherPanel!
    private var selectedIDs: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        switcher = SwitcherPanel(screen: screen, onActivate: { _ in },
                                 onSelect: { [unowned self] in self.selectedIDs.append($0) })
    }

    override func tearDown() async throws {
        switcher.hideSwitcher()
        switcher.close()
        switcher = nil
    }

    private func move(to index: Int, offset: CGFloat = 0) {
        switcher.smokeMove(to: index, pointer: NSPoint(x: switcher.smokeHoverOrigin.x + offset,
                                                       y: switcher.smokeHoverOrigin.y))
    }

    func testPointerSelectsOnlyAfterMovingAndKeyboardResetsHover() {
        let windows = (0..<200).map {
            WindowInfo(id: "smoke-\($0)", appID: "smoke", appName: "Smoke",
                       title: "Window \($0) " + String(repeating: "Long title ", count: 40),
                       processID: ProcessInfo.processInfo.processIdentifier)
        }
        let results = WindowSearch.filter(windows, query: "")
        let initialIndex = windows.count - 1
        switcher.show(results: results, selectedIndex: initialIndex)
        switcher.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(switcher.smokeLayoutIsValid, switcher.smokeLayoutDescription)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [initialIndex])

        move(to: 0)
        XCTAssertEqual(selectedIDs, [], "a stationary pointer selected a row")
        XCTAssertEqual(switcher.smokeHighlightedIndices, [initialIndex])
        move(to: 0, offset: 1)
        XCTAssertEqual(selectedIDs, [windows[0].id])
        switcher.update(results: results, selectedIndex: 0)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [0])

        switcher.update(results: results, selectedIndex: 1, resetHover: true)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [1])
        move(to: 0)
        XCTAssertEqual(selectedIDs.count, 1, "keyboard selection was overridden by a stationary pointer")
        XCTAssertEqual(switcher.smokeHighlightedIndices, [1])
        move(to: 2, offset: 1)
        XCTAssertEqual(selectedIDs, [windows[0].id, windows[2].id])
        switcher.update(results: results, selectedIndex: 2)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [2])

        switcher.show(results: results, selectedIndex: initialIndex)
        move(to: 0)
        XCTAssertEqual(selectedIDs.count, 2, "showing again did not reset the hover origin")
        XCTAssertEqual(switcher.smokeHighlightedIndices, [initialIndex])

        let originalFrame = switcher.frame
        let query = "smoke 199"
        let searchResults = WindowSearch.filter(windows, query: query)
        switcher.update(results: searchResults, selectedIndex: 0, resetHover: true, query: "  " + query + "  ",
                        totalWindowCount: windows.count, language: .zh)
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(switcher.frame, originalFrame)
        XCTAssertEqual(switcher.smokeSearchHeader.query, query)
        XCTAssertEqual(switcher.smokeSearchHeader.count, "1 个结果")
        XCTAssertFalse(switcher.smokeSearchHeader.empty)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [0])
        XCTAssertTrue(switcher.smokeSearchHighlightsAreValid)
        move(to: 0)
        XCTAssertEqual(selectedIDs.count, 2, "search reset did not keep the selection")

        switcher.update(results: [], selectedIndex: 0, query: "zzzz", totalWindowCount: windows.count, language: .zh)
        XCTAssertEqual(switcher.frame, originalFrame)
        XCTAssertTrue(switcher.smokeSearchHeader.empty)
        XCTAssertEqual(switcher.smokeSearchHeader.count, "0 个结果")
        XCTAssertEqual(switcher.smokeHighlightedIndices, [])
        XCTAssertFalse(switcher.smokeSearchHeader.hasSelection)

        switcher.update(results: results, selectedIndex: initialIndex, language: .en)
        switcher.update(results: results, selectedIndex: initialIndex, query: " \t ", language: .en)
        XCTAssertEqual(switcher.smokeSearchHeader.query, "Type an app name or window title")
        XCTAssertEqual(switcher.smokeSearchHeader.count, "200 windows")
        XCTAssertFalse(switcher.smokeSearchHeader.empty)
        XCTAssertTrue(switcher.smokeLayoutIsValid, switcher.smokeLayoutDescription)
        XCTAssertEqual(switcher.smokeHighlightedIndices, [initialIndex])
    }

    func testSearchHighlightingKeepsLongTextLayout() {
        let windows = [
            WindowInfo(id: "long-title", appID: "chrome", appName: "Google Chrome",
                       title: String(repeating: "OpenContexts window search and a long browser title — ", count: 20),
                       processID: 0),
            WindowInfo(id: "long-app", appID: "long-app",
                       appName: String(repeating: "OpenContexts ", count: 20), title: "Open a document", processID: 0)
        ]
        let results = WindowSearch.filter(windows, query: "")
        let searchResults = WindowSearch.filter(windows, query: "open")
        switcher.show(results: results, selectedIndex: 0)
        for selected in windows.indices {
            switcher.update(results: results, selectedIndex: selected)
            let normal = switcher.smokeTextLayouts
            switcher.update(results: searchResults, selectedIndex: selected, query: "open")
            XCTAssertEqual(switcher.smokeTextLayouts, normal, "selected=\(selected)")
        }
    }

    func testDesktopHeadersGroupWindowsBySpace() {
        let windows = [
            WindowInfo(id: "current-space", appID: "Editor", appName: "Editor", title: "Project", processID: 0,
                       space: WindowSpace(id: 2, index: 2, isCurrent: true)),
            WindowInfo(id: "other-space", appID: "Browser", appName: "Browser", title: "Project", processID: 0,
                       space: WindowSpace(id: 1, index: 1, isCurrent: false))
        ]
        let grouped = WindowSwitcher.filter(windows, query: "", allSpaces: true)
        switcher.show(results: grouped, selectedIndex: 1, groupBySpace: true, language: .zh)
        switcher.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(switcher.smokeSpaceHeaders, ["桌面 2 · 当前", "桌面 1"])
        XCTAssertEqual(switcher.smokeHighlightedIndices, [1])
        move(to: 0, offset: 1)
        XCTAssertEqual(selectedIDs.last, "current-space", "desktop header intercepted window hover selection")

        switcher.update(results: WindowSwitcher.filter(windows, query: "browser", allSpaces: true),
                        selectedIndex: 0, groupBySpace: true, query: "browser", language: .zh)
        XCTAssertEqual(switcher.smokeSpaceHeaders, ["桌面 1"])
        XCTAssertEqual(switcher.smokeHighlightedIndices, [0])
        switcher.update(results: grouped, selectedIndex: 0, groupBySpace: false)
        XCTAssertEqual(switcher.smokeSpaceHeaders, [])
    }
}
