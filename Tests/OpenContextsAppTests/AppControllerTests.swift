import AppKit
import XCTest
@testable import OpenContextsApp

@MainActor
final class AppControllerTests: XCTestCase {
    func testPointerOnAScreensTopEdgeBelongsToThatScreen() {
        let lower = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let upper = NSRect(x: 0, y: 800, width: 1000, height: 600)
        let side = NSRect(x: 1000, y: 0, width: 500, height: 800)
        let frames = [lower, upper, side]
        XCTAssertEqual(AppController.screenIndex(containing: NSPoint(x: 10, y: 800), frames: [lower]), 0,
                       "the top edge of the only screen matched no screen")
        XCTAssertEqual(AppController.screenIndex(containing: NSPoint(x: 10, y: 800), frames: frames), 0)
        XCTAssertEqual(AppController.screenIndex(containing: NSPoint(x: 10, y: 1400), frames: frames), 1)
        XCTAssertEqual(AppController.screenIndex(containing: NSPoint(x: 10, y: 801), frames: frames), 1)
        XCTAssertEqual(AppController.screenIndex(containing: NSPoint(x: 1000, y: 10), frames: frames), 2)
        XCTAssertNil(AppController.screenIndex(containing: NSPoint(x: 10, y: 0), frames: [lower]))
        XCTAssertNil(AppController.screenIndex(containing: NSPoint(x: -1, y: 10), frames: frames))

        var random = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let point = NSPoint(x: CGFloat.random(in: -10...1510, using: &random).rounded(),
                                y: CGFloat.random(in: -10...1410, using: &random).rounded())
            let matches = frames.indices.filter { NSMouseInRect(point, frames[$0], false) }
            XCTAssertLessThanOrEqual(matches.count, 1, "\(point) belongs to several screens")
            XCTAssertEqual(AppController.screenIndex(containing: point, frames: frames), matches.first, "\(point)")
        }
    }
}
