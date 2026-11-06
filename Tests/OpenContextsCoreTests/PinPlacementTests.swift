import XCTest
@testable import OpenContextsCore

final class PinPlacementTests: XCTestCase {
    func testAvailablePositionIsAFreeSlotInRange() {
        var random = SeededGenerator(seed: 1)
        for iteration in 0..<5_000 {
            let count = Int.random(in: 0...8, using: &random)
            let occupied = Set((0..<Int.random(in: 0...10, using: &random)).map { _ in
                Int.random(in: -3...11, using: &random)
            })
            let requested = Int.random(in: Int.min...Int.max, using: &random) % 12
            let position = GroupStore.availablePinnedPosition(requested, occupied: occupied, count: count)
            let free = (0..<max(count, 0)).filter { !occupied.contains($0) }
            let message = "iteration \(iteration): requested \(requested), occupied \(occupied), count \(count)"
            guard let position else {
                XCTAssertTrue(free.isEmpty, message)
                continue
            }
            XCTAssertTrue(free.contains(position), message)
            if free.contains(requested) { XCTAssertEqual(position, requested, message) }
        }
    }

    func testArrangementIsAPermutationForAdversarialInput() {
        var random = SeededGenerator(seed: 2)
        let alphabet = ["a", "b", "c", "d", "e", "f"]
        for iteration in 0..<5_000 {
            let ids = (0..<Int.random(in: 0...8, using: &random)).map { _ in alphabet.randomElement(using: &random)! }
            let pinned = (0..<Int.random(in: 0...8, using: &random)).map { _ in
                (alphabet.randomElement(using: &random)! + (Bool.random(using: &random) ? "" : "?"),
                 Int.random(in: -1_000...1_000, using: &random))
            }
            let arranged = GroupStore.arrangedWindowIDs(ids, pinned: pinned)
            var seen = Set<String>()
            let unique = ids.filter { seen.insert($0).inserted }
            let message = "iteration \(iteration): ids \(ids), pinned \(pinned)"
            XCTAssertEqual(arranged.count, unique.count, message)
            XCTAssertEqual(Set(arranged), Set(unique), message)

            let pinnedIDs = Set(pinned.map(\.0)).intersection(unique)
            XCTAssertEqual(arranged.filter { !pinnedIDs.contains($0) }, unique.filter { !pinnedIDs.contains($0) },
                           "unpinned order changed: \(message)")
        }
    }

    func testFirstPinInRangeLandsExactlyOnItsSlot() {
        var random = SeededGenerator(seed: 3)
        for _ in 0..<2_000 {
            let ids = (0..<Int.random(in: 1...8, using: &random)).map { "w\($0)" }
            let id = ids.randomElement(using: &random)!
            let slot = Int.random(in: 0..<ids.count, using: &random)
            let arranged = GroupStore.arrangedWindowIDs(ids, pinned: [(id, slot), (id, 0)])
            XCTAssertEqual(arranged.firstIndex(of: id), slot, "ids \(ids), pinned \(id) at \(slot)")
        }
    }

    func testRegressionsForInputsThatUsedToCrash() {
        XCTAssertEqual(GroupStore.arrangedWindowIDs(["a"], pinned: [("a", 0), ("a", 0)]), ["a"])
        XCTAssertEqual(GroupStore.arrangedWindowIDs(["a", "b"], pinned: [("a", -1)]), ["a", "b"])
        XCTAssertEqual(GroupStore.arrangedWindowIDs(["a", "a", "b"], pinned: [("a", 2)]), ["b", "a"])
        XCTAssertNil(GroupStore.availablePinnedPosition(0, occupied: [0], count: 1))
        XCTAssertEqual(GroupStore.availablePinnedPosition(-3, occupied: [], count: 3), 0)
    }
}
