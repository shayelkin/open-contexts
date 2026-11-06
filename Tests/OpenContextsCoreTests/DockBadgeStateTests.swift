import Foundation
import XCTest
@testable import OpenContextsCore

final class DockBadgeStateTests: XCTestCase {
    func testMapsApplicationURLAndMergesClearFailureAndSharedAppWindows() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.shared", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: appURL) }

        let appID = try XCTUnwrap(DockBadgeState.appID(for: appURL))
        XCTAssertEqual(appID, "com.example.shared")
        let windowAppIDs = [appID, appID]

        var state = DockBadgeState()
        state.merge(activeAppIDs: Set(windowAppIDs), reads: [appID: .value("123")])
        XCTAssertEqual(windowAppIDs.map { state.badges[$0] }, ["99+", "99+"])

        state.merge(activeAppIDs: Set(windowAppIDs), reads: nil)
        XCTAssertEqual(state.badges[appID], "99+")
        state.merge(activeAppIDs: Set(windowAppIDs), reads: [appID: .failure])
        XCTAssertEqual(state.badges[appID], "99+")
        state.merge(activeAppIDs: Set(windowAppIDs), reads: [appID: .value(nil)])
        XCTAssertNil(state.badges[appID])

        state.merge(activeAppIDs: Set(windowAppIDs), reads: [appID: .value("•")])
        XCTAssertEqual(state.badges[appID], "•")
        XCTAssertEqual(DockBadgeState.displayValue("1"), "1")
        XCTAssertEqual(DockBadgeState.displayValue("12"), "12")
        XCTAssertEqual(DockBadgeState.displayValue("100"), "99+")
        XCTAssertEqual(DockBadgeState.displayValue("99+"), "99+")
        XCTAssertEqual(DockBadgeState.displayValue("new"), "•")
        XCTAssertNil(DockBadgeState.displayValue(nil))
        state.merge(activeAppIDs: [], reads: nil)
        XCTAssertTrue(state.badges.isEmpty)
    }

    func testDisplayValueProperties() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let count = Int.random(in: -5...1_000, using: &random)
            let padding = [" ", "\n", "\t", ""].randomElement(using: &random)!
            let plain = DockBadgeState.displayValue(padding + String(count) + padding)
            switch count {
            case ..<0: XCTAssertEqual(plain, "•")
            case 0: XCTAssertNil(plain)
            case 1...99: XCTAssertEqual(plain, String(count))
            default: XCTAssertEqual(plain, "99+")
            }
            let plus = DockBadgeState.displayValue(String(count) + "+")
            switch count {
            case ..<1: XCTAssertEqual(plus, "•")
            case 1..<99: XCTAssertEqual(plus, "\(count)+")
            default: XCTAssertEqual(plus, "99+")
            }
            for value in [plain, plus].compactMap({ $0 }) {
                XCTAssertLessThanOrEqual(value.count, 3, "badge \(value) does not fit")
            }
        }
        for blank in [nil, "", " ", "\n\t"] { XCTAssertNil(DockBadgeState.displayValue(blank)) }
        for text in ["new", "!", "1.5", "+", "١٢"] { XCTAssertEqual(DockBadgeState.displayValue(text), "•", text) }
    }

    func testMergeOnlyKeepsBadgesOfActiveAppsAndFailuresKeepTheLastValue() {
        var random = SystemRandomNumberGenerator()
        let apps = ["a", "b", "c", "d"]
        for _ in 0..<500 {
            var state = DockBadgeState()
            for _ in 0..<10 {
                let previous = state.badges
                let active = Set(apps.filter { _ in Bool.random(using: &random) })
                let reads: [String: DockBadgeRead]? = Bool.random(using: &random) ? nil : Dictionary(
                    uniqueKeysWithValues: apps.filter { _ in Bool.random(using: &random) }.map { app in
                        (app, Bool.random(using: &random) ? .failure : .value(["3", nil, "x", "0"].randomElement(using: &random)!))
                    })
                state.merge(activeAppIDs: active, reads: reads)
                XCTAssertTrue(Set(state.badges.keys).isSubset(of: active))
                for app in active {
                    switch reads?[app] {
                    case let .value(raw): XCTAssertEqual(state.badges[app], DockBadgeState.displayValue(raw))
                    case .failure, nil: XCTAssertEqual(state.badges[app], previous[app])
                    }
                }
            }
        }
    }
}
