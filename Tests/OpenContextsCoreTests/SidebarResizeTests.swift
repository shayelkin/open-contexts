import CoreGraphics
import XCTest
@testable import OpenContextsCore

final class SidebarResizeTests: XCTestCase {
    private let range: ClosedRange<CGFloat> = 94...376

    func testWidthFollowsPointerTowardTheScreenInterior() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let start = CGFloat.random(in: range, using: &generator).rounded()
            let startX = CGFloat.random(in: -3000...3000, using: &generator)
            let delta = CGFloat.random(in: -500...500, using: &generator)
            let dockedRight = Bool.random(using: &generator)
            let width = SidebarResize.width(startWidth: start, startPointerX: startX, pointerX: startX + delta,
                                            dockedRight: dockedRight, range: range)
            let expected = min(max((start + (dockedRight ? -delta : delta)).rounded(), range.lowerBound),
                               range.upperBound)
            XCTAssertEqual(width, expected)
            XCTAssertTrue(range.contains(width))
            XCTAssertEqual(width, width.rounded())
        }
    }

    func testWidthIsMonotonicInPointerMovement() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let start = CGFloat.random(in: range, using: &generator)
            let startX = CGFloat.random(in: -3000...3000, using: &generator)
            let a = CGFloat.random(in: -600...600, using: &generator)
            let b = CGFloat.random(in: -600...600, using: &generator)
            let dockedRight = Bool.random(using: &generator)
            func width(_ delta: CGFloat) -> CGFloat {
                SidebarResize.width(startWidth: start, startPointerX: startX, pointerX: startX + delta,
                                    dockedRight: dockedRight, range: range)
            }
            let (low, high) = (min(a, b), max(a, b))
            dockedRight
                ? XCTAssertGreaterThanOrEqual(width(low), width(high))
                : XCTAssertLessThanOrEqual(width(low), width(high))
        }
    }

    func testNoMovementKeepsTheClampedStartWidth() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let start = CGFloat.random(in: -1000...1000, using: &generator)
            let x = CGFloat.random(in: -3000...3000, using: &generator)
            for dockedRight in [false, true] {
                XCTAssertEqual(SidebarResize.width(startWidth: start, startPointerX: x, pointerX: x,
                                                   dockedRight: dockedRight, range: range),
                               min(max(start.rounded(), range.lowerBound), range.upperBound))
            }
        }
    }

    func testNonFiniteInputsStayInRange() {
        let values: [CGFloat] = [.nan, .infinity, -.infinity, 0, 188]
        for start in values {
            for startX in values {
                for x in values {
                    for dockedRight in [false, true] {
                        let width = SidebarResize.width(startWidth: start, startPointerX: startX, pointerX: x,
                                                        dockedRight: dockedRight, range: range)
                        XCTAssertTrue(range.contains(width), "start=\(start) startX=\(startX) x=\(x) -> \(width)")
                    }
                }
            }
        }
        XCTAssertEqual(SidebarResize.width(startWidth: 188, startPointerX: 0, pointerX: .nan,
                                           dockedRight: true, range: range), 188)
    }
}
