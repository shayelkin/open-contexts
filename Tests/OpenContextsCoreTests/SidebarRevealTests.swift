import CoreGraphics
import XCTest
@testable import OpenContextsCore

final class SidebarRevealTests: XCTestCase {
    func testEasingIsClampedMonotonicAndHitsEndpoints() {
        XCTAssertEqual(SidebarReveal.eased(0), 0)
        XCTAssertEqual(SidebarReveal.eased(1), 1)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let a = Double.random(in: -2...3, using: &generator)
            let b = Double.random(in: -2...3, using: &generator)
            let (low, high) = (min(a, b), max(a, b))
            XCTAssertLessThanOrEqual(SidebarReveal.eased(low), SidebarReveal.eased(high))
            XCTAssertTrue((0...1).contains(SidebarReveal.eased(a)))
            XCTAssertGreaterThanOrEqual(SidebarReveal.eased(min(max(a, 0), 1)), min(max(a, 0), 1))
        }
        XCTAssertEqual(SidebarReveal.eased(.nan).isNaN, false)
    }

    func testStepMovesTowardTargetWithoutOvershooting() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let progress = Double.random(in: 0...1, using: &generator)
            let target: Double = Bool.random(using: &generator) ? 1 : 0
            let elapsed = Double.random(in: 0...0.5, using: &generator)
            let next = SidebarReveal.step(progress: progress, toward: target, elapsed: elapsed)
            XCTAssertTrue((0...1).contains(next))
            XCTAssertLessThanOrEqual(abs(target - next), abs(target - progress) + 1e-12)
            XCTAssertEqual(abs(next - progress), min(elapsed / SidebarReveal.duration, abs(target - progress)),
                           accuracy: 1e-9)
        }
    }

    func testStepIsFrameRateIndependent() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let ticks = (0..<Int.random(in: 1...40, using: &generator)).map { _ in
                Double.random(in: 0...0.05, using: &generator)
            }
            let total = ticks.reduce(0, +)
            var progress = 0.0
            ticks.forEach { progress = SidebarReveal.step(progress: progress, toward: 1, elapsed: $0) }
            XCTAssertEqual(progress, min(total / SidebarReveal.duration, 1), accuracy: 1e-9)
            XCTAssertEqual(progress == 1, total >= SidebarReveal.duration - 1e-12)
        }
    }

    func testStepHandlesDegenerateInputs() {
        XCTAssertEqual(SidebarReveal.step(progress: 0.3, toward: 1, elapsed: -1), 0.3)
        XCTAssertEqual(SidebarReveal.step(progress: 0.3, toward: 1, elapsed: .infinity), 1)
        XCTAssertEqual(SidebarReveal.step(progress: 0.3, toward: 0, elapsed: .nan), 0)
        XCTAssertEqual(SidebarReveal.step(progress: 0.3, toward: 1, elapsed: 0.01, duration: 0), 1)
        XCTAssertEqual(SidebarReveal.step(progress: 5, toward: 7, elapsed: 0), 1)
        XCTAssertEqual(SidebarReveal.step(progress: -5, toward: -7, elapsed: 0), 0)
        XCTAssertEqual(SidebarReveal.step(progress: .nan, toward: 1, elapsed: 0), 0)
        XCTAssertEqual(SidebarReveal.step(progress: 0.5, toward: .nan, elapsed: 1), 0)
    }

    func testFrameStaysAnchoredToDockedEdgeAndGrowsMonotonically() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let expanded = CGRect(x: CGFloat.random(in: -2000...2000, using: &generator),
                                  y: CGFloat.random(in: -1000...1000, using: &generator),
                                  width: CGFloat.random(in: 1...600, using: &generator),
                                  height: CGFloat.random(in: 1...1200, using: &generator))
            let edge = SidebarReveal.Edge.allCases.randomElement(using: &generator)!
            let a = Double.random(in: 0...1, using: &generator)
            let b = Double.random(in: 0...1, using: &generator)
            let small = SidebarReveal.frame(expanded: expanded, edge: edge, progress: min(a, b))
            let large = SidebarReveal.frame(expanded: expanded, edge: edge, progress: max(a, b))
            for frame in [small, large] {
                XCTAssertTrue(expanded.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(frame) outside \(expanded)")
                XCTAssertGreaterThanOrEqual(min(frame.width, frame.height), min(1, expanded.width, expanded.height))
                switch edge {
                case .left:
                    XCTAssertEqual(frame.minX, expanded.minX)
                    XCTAssertEqual(frame.height, expanded.height)
                case .right:
                    XCTAssertEqual(frame.maxX, expanded.maxX, accuracy: 1e-9)
                    XCTAssertEqual(frame.height, expanded.height)
                case .bottom:
                    XCTAssertEqual(frame.minY, expanded.minY)
                    XCTAssertEqual(frame.width, expanded.width)
                }
            }
            XCTAssertLessThanOrEqual(small.width * small.height, large.width * large.height + 1e-6)
        }
    }

    func testFrameEndpoints() {
        let expanded = CGRect(x: 1252, y: 300, width: 188, height: 400)
        XCTAssertEqual(SidebarReveal.frame(expanded: expanded, edge: .right, progress: 1), expanded)
        XCTAssertEqual(SidebarReveal.frame(expanded: expanded, edge: .left, progress: 1), expanded)
        XCTAssertEqual(SidebarReveal.frame(expanded: expanded, edge: .bottom, progress: 1), expanded)
        XCTAssertEqual(SidebarReveal.frame(expanded: expanded, edge: .right, progress: 0),
                       CGRect(x: 1439, y: 300, width: 1, height: 400))
        XCTAssertEqual(SidebarReveal.frame(expanded: expanded, edge: .bottom, progress: 0),
                       CGRect(x: 1252, y: 300, width: 188, height: 1))
    }
}
