import CoreGraphics
import XCTest
@testable import OpenContextsCore

final class SidebarTooltipLayoutTests: XCTestCase {
    private let screens = [
        CGRect(x: 0, y: 0, width: 1440, height: 875),
        CGRect(x: -1920, y: 120, width: 1920, height: 1055),
        CGRect(x: 1440, y: -300, width: 800, height: 1200)
    ]

    func testTooltipIsNeededOnlyForHiddenOrTruncatedTitles() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let titleWidth = CGFloat.random(in: 0...2000, using: &generator)
            let availableWidth = CGFloat.random(in: 0...2000, using: &generator)
            XCTAssertTrue(SidebarTooltipLayout.needsTooltip(showsTitle: false, titleWidth: titleWidth,
                                                            availableWidth: availableWidth))
            XCTAssertEqual(SidebarTooltipLayout.needsTooltip(showsTitle: true, titleWidth: titleWidth,
                                                             availableWidth: availableWidth),
                           titleWidth > availableWidth)
            XCTAssertFalse(SidebarTooltipLayout.needsTooltip(showsTitle: true, titleWidth: titleWidth,
                                                             availableWidth: titleWidth))
        }
    }

    func testInitialDelayConvertsSystemMilliseconds() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let milliseconds = Int.random(in: 0...60_000, using: &generator)
            let expected = Double(milliseconds) / 1000
            XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: NSNumber(value: milliseconds)), expected)
            XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: String(milliseconds)), expected)
            let fractional = Double.random(in: 0...60_000, using: &generator)
            XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: NSNumber(value: fractional)),
                           fractional / 1000)
        }
    }

    func testInitialDelayFallsBackForMissingOrInvalidValues() {
        var generator = SystemRandomNumberGenerator()
        let fallback = SidebarTooltipLayout.fallbackInitialDelay
        XCTAssertEqual(fallback, 1.5)
        let invalid: [Any?] = [nil, "", "soon", "1e", "-1", "nan", "inf", NSNumber(value: Double.nan),
                               NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
                               Date(), [1000], ["delay": 1000]]
        invalid.forEach { XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: $0), fallback, "\(String(describing: $0))") }
        for _ in 0..<500 {
            let negative = -Double.random(in: Double.leastNonzeroMagnitude...1e9, using: &generator)
            XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: NSNumber(value: negative)), fallback)
            XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: String(negative)), fallback)
        }
    }

    func testInitialDelayReadsUserDefaults() throws {
        let suite = "SidebarTooltipLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SidebarTooltipLayout.initialDelayDefaultsKey
        XCTAssertEqual(key, "NSInitialToolTipDelay")
        defaults.set(250, forKey: key)
        XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: defaults.object(forKey: key)), 0.25)
        defaults.set("2000", forKey: key)
        XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: defaults.object(forKey: key)), 2)
        defaults.removeObject(forKey: key)
        XCTAssertEqual(SidebarTooltipLayout.initialDelay(milliseconds: defaults.object(forKey: key)),
                       SidebarTooltipLayout.fallbackInitialDelay)
    }

    func testFrameAlwaysStaysOnScreen() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let screen = screens.randomElement(using: &generator)!
            let size = CGSize(width: CGFloat.random(in: 1...(screen.width * 1.5), using: &generator),
                              height: CGFloat.random(in: 1...(screen.height * 1.5), using: &generator))
            let pointer = CGPoint(x: CGFloat.random(in: (screen.minX - 200)...(screen.maxX + 200), using: &generator),
                                  y: CGFloat.random(in: (screen.minY - 200)...(screen.maxY + 200), using: &generator))
            let frame = SidebarTooltipLayout.frame(size: size, pointer: pointer, screen: screen)
            XCTAssertTrue(screen.contains(frame), "\(frame) escaped \(screen)")
            XCTAssertEqual(frame.width, min(size.width, screen.width))
            XCTAssertEqual(frame.height, min(size.height, screen.height))
        }
    }

    func testFrameNeverCoversPointerWhenThereIsRoom() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let screen = screens.randomElement(using: &generator)!
            let size = CGSize(width: CGFloat.random(in: 1...600, using: &generator),
                              height: CGFloat.random(in: 1...200, using: &generator))
            let pointer = CGPoint(x: CGFloat.random(in: screen.minX..<screen.maxX, using: &generator),
                                  y: CGFloat.random(in: screen.minY..<screen.maxY, using: &generator))
            let roomBelow = pointer.y - screen.minY >= SidebarTooltipLayout.pointerClearance + size.height
            let roomAbove = screen.maxY - pointer.y >= SidebarTooltipLayout.gap + size.height
            guard roomBelow || roomAbove else { continue }
            let frame = SidebarTooltipLayout.frame(size: size, pointer: pointer, screen: screen)
            XCTAssertFalse(frame.insetBy(dx: 0, dy: 0.5).contains(pointer), "\(frame) covers \(pointer)")
            XCTAssertEqual(frame.maxY <= pointer.y, roomBelow)
        }
    }

    func testFramePrefersBelowAndRightOfPointer() {
        let screen = screens[0]
        let frame = SidebarTooltipLayout.frame(size: CGSize(width: 200, height: 20),
                                               pointer: CGPoint(x: 100, y: 400), screen: screen)
        XCTAssertEqual(frame, CGRect(x: 100, y: 360, width: 200, height: 20))
    }

    func testFrameShiftsLeftAtRightEdgeAndAboveAtBottomEdge() {
        let screen = screens[0]
        let frame = SidebarTooltipLayout.frame(size: CGSize(width: 300, height: 40),
                                               pointer: CGPoint(x: 1430, y: 10), screen: screen)
        XCTAssertEqual(frame, CGRect(x: 1140, y: 14, width: 300, height: 40))
    }
}
