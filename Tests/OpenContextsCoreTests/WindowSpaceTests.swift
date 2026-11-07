import PropertyBased
import Testing
@testable import OpenContextsCore

private let appNames = ["Code", "code", "My Code", "Alpha", "Zulu", "Écran"]
private let titles = ["", " ", "Project", "project", "Code 2", "Code 10"]

/// 1–5 spaces with distinct IDs and Mission Control indexes, each randomly current and desktop or full screen.
private let spaces = zip(Gen<[Int]>.shuffled(Array(1...8)), Gen.bool.array(of: 5), Gen.bool.array(of: 5), Gen.int(in: 1...5))
    .map { indexes, isCurrent, isFullscreen, count in
        (0..<count).map { i in
            WindowSpace(id: UInt64(100 + i), index: indexes[i], isCurrent: isCurrent[i],
                        kind: isFullscreen[i] ? .fullscreen : .desktop(number: indexes[i]))
        }
    }

/// Up to 12 windows, as indexes into `appNames`, `titles` and the spaces, where 0 is an unknown space.
private let windowSpecs = zip(Gen.int(in: 0..<appNames.count), Gen.int(in: 0..<titles.count), Gen.int(in: 0...5))
    .array(of: 0...12)

private let query = Gen<String?>.element(of: ["", "code", "co", "a", "pro", "zz", "c p", "my code"]).map { $0! }

private func makeWindows(_ spaces: [WindowSpace], _ specs: [(Int, Int, Int)]) -> [WindowInfo] {
    specs.enumerated().map { n, spec in
        WindowInfo(id: "w\(n)", appID: appNames[spec.0], appName: appNames[spec.0], title: titles[spec.1],
                   processID: 1, space: spec.2 == 0 ? nil : spaces[(spec.2 - 1) % spaces.count])
    }
}

/// The first window of each run of consecutive windows on the same space.
private func runs(_ windows: [WindowInfo]) -> [WindowInfo] {
    windows.enumerated().filter { $0.offset == 0 || windows[$0.offset - 1].space?.id != $0.element.space?.id }
        .map(\.element)
}

private func forEachScenario(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: ([WindowInfo], String) -> Void
) async {
    await propertyCheck(count: 500, input: spaces, windowSpecs, query, perform: { spaces, specs, query in
        body(makeWindows(spaces, specs), query)
    }, sourceLocation: sourceLocation)
}

private func switcher(_ windows: [WindowInfo], _ query: String = "", allSpaces: Bool = true) -> [WindowInfo] {
    WindowSwitcher.filter(windows, query: query, allSpaces: allSpaces).map(\.window)
}

struct WindowSpaceTests {
    @Test func searchReturnsEachMatchingWindowOnce() async {
        await forEachScenario { windows, query in
            let matching = windows.filter { WindowSearch.match($0, query: query) != nil }
            let all = switcher(windows, query)
            #expect(all.map(\.id).sorted() == matching.map(\.id).sorted(), "should list every match once")
            let current = switcher(windows, query, allSpaces: false)
            #expect(current.map(\.id).sorted() == matching.filter(\.isOnCurrentSpace).map(\.id).sorted(),
                    "should list every match on the current space once")
        }
    }

    @Test func currentSpaceOnlyKeepsRecentOrder() async {
        await forEachScenario { windows, _ in
            #expect(switcher(windows, allSpaces: false) == windows.filter(\.isOnCurrentSpace),
                    "should keep current-space windows in recent order")
        }
    }

    @Test func currentSpacesComeFirst() async {
        await forEachScenario { windows, query in
            let afterFirstOtherSpace = switcher(windows, query).drop { $0.isOnCurrentSpace }
            #expect(!afterFirstOtherSpace.contains { $0.isOnCurrentSpace },
                    "no current-space window should follow another space's window")
        }
    }

    @Test func eachSpaceIsListedTogether() async {
        await forEachScenario { windows, query in
            let spaceIDs = runs(switcher(windows, query)).map(\.space?.id)
            #expect(Set(spaceIDs).count == spaceIDs.count, "a space's windows should not be split")
        }
    }

    @Test func spacesFollowMissionControlOrder() async {
        await forEachScenario { windows, query in
            let runs = runs(switcher(windows, query))
            for isCurrent in [true, false] {
                let indexes = runs.filter { $0.isOnCurrentSpace == isCurrent }.map { $0.space?.index ?? 0 }
                #expect(indexes == indexes.sorted(), "spaces should follow Mission Control order")
            }
        }
    }

    @Test func currentSpacesKeepRecentOrder() async {
        await forEachScenario { windows, _ in
            let results = switcher(windows)
            for spaceID in Set(windows.filter(\.isOnCurrentSpace).map(\.space?.id)) {
                #expect(results.filter { $0.space?.id == spaceID } == windows.filter { $0.space?.id == spaceID },
                        "a current space should keep its windows in recent order")
            }
        }
    }

    @Test func otherSpacesListAppsAlphabetically() async {
        await forEachScenario { windows, _ in
            let others = switcher(windows).filter { !$0.isOnCurrentSpace }
            for (a, b) in zip(others, others.dropFirst()) where a.space?.id == b.space?.id {
                #expect(a.appName.localizedStandardCompare(b.appName) != .orderedDescending,
                        "\(a.appName) should not come after \(b.appName)")
            }
        }
    }

    @Test func otherSpacesIgnoreRecentOrder() async {
        await propertyCheck(count: 500, input: spaces, windowSpecs, query, Gen<[Int]>.shuffled(Array(0..<12))) {
            spaces, specs, query, permutation in
            let windows = makeWindows(spaces, specs)
            let shuffled = permutation.filter { $0 < windows.count }.map { windows[$0] }
            #expect(switcher(shuffled, query).filter { !$0.isOnCurrentSpace }
                        == switcher(windows, query).filter { !$0.isOnCurrentSpace },
                    "other spaces' order should not depend on recent order")
        }
    }

    @Test func visibleSpacesDropOnlyOtherSpaces() async {
        await forEachScenario { windows, _ in
            #expect(windows.onVisibleSpaces(allSpaces: true) == windows, "all spaces should keep every window")
            #expect(windows.onVisibleSpaces(allSpaces: false) == windows.filter { $0.space?.isCurrent != false },
                    "should keep windows on current or unknown spaces, in order")
        }
    }
}
