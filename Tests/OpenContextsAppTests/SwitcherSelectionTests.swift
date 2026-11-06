import XCTest
@testable import OpenContextsApp

final class SwitcherSelectionTests: XCTestCase {
    func testSteppingWrapsLikeModularArithmetic() {
        var random = SystemRandomNumberGenerator()
        let edges = [Int.min, Int.min + 1, -7, -1, 0, 1, 7, Int.max - 1, Int.max]
        for _ in 0..<5_000 {
            let count = Int.random(in: 1...9, using: &random)
            let index = Bool.random(using: &random) ? Int.random(in: 0..<count, using: &random)
                : edges.randomElement(using: &random)!
            let amount = Bool.random(using: &random) ? Int.random(in: -20...20, using: &random)
                : edges.randomElement(using: &random)!
            let stepped = SwitcherSelection.stepped(index, by: amount, count: count)
            let message = "index \(index), amount \(amount), count \(count)"
            XCTAssertTrue((0..<count).contains(stepped), message)
            let expected = ((index % count + amount % count) % count + count) % count
            XCTAssertEqual(stepped, expected, message)
            if (0..<count).contains(index), (-count...count).contains(amount) {
                XCTAssertEqual(SwitcherSelection.stepped(stepped, by: -amount, count: count), index,
                               "stepping back did not return: \(message)")
            }
        }
        XCTAssertEqual(SwitcherSelection.stepped(3, by: 1, count: 0), 0)
        XCTAssertEqual(SwitcherSelection.stepped(0, by: -1, count: 4), 3)
        XCTAssertEqual(SwitcherSelection.stepped(3, by: 1, count: 4), 0)
    }

    func testInitialSelectionSkipsTheFocusedWindowAndReverseStartsAtTheEnd() {
        for count in 0...5 {
            for focused in [false, true] {
                XCTAssertEqual(SwitcherSelection.initial(count: count, firstIsFocused: focused, reverse: true),
                               max(count - 1, 0))
                XCTAssertEqual(SwitcherSelection.initial(count: count, firstIsFocused: focused, reverse: false),
                               focused && count > 1 ? 1 : 0)
            }
        }
    }

    func testPreservedSelectionFollowsTheWindowOrClampsTheFallback() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let ids = (0..<Int.random(in: 0...6, using: &random)).map { "w\($0)" }.shuffled(using: &random)
            let selected = Bool.random(using: &random) ? ids.randomElement(using: &random) : "gone"
            let fallback = Int.random(in: -3...9, using: &random)
            let index = SwitcherSelection.preserved(selected, in: ids, fallback: fallback)
            if let selected, let expected = ids.firstIndex(of: selected) {
                XCTAssertEqual(index, expected)
            } else {
                XCTAssertEqual(index, ids.isEmpty ? 0 : min(max(fallback, 0), ids.count - 1))
            }
        }
        XCTAssertEqual(SwitcherSelection.preserved(nil, in: ["a", "b"], fallback: 5), 1)
    }
}
