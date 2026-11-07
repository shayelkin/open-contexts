import Foundation
import PropertyBased
import Testing
@testable import OpenContextsCore

private let unicodeWhitespace: [Character] = (UInt32(0)...0x10FFFF)
    .compactMap { Unicode.Scalar($0) }
    .filter { CharacterSet.whitespacesAndNewlines.contains($0) }
    .map(Character.init)

private let whitespace = Gen<Character?>.element(of: unicodeWhitespace).map { $0! }.string(of: 0...20)

private let padding = zip(whitespace, Gen.int(in: 0...20), whitespace)

private func padded(_ text: String, _ padding: (leading: String, zeroCount: Int, trailing: String)) -> String {
    padding.leading + String(repeating: "0", count: padding.zeroCount) + text + padding.trailing
}

private let digitsAndPluses = Gen<Character?>.element(of: Array("0123456789+")).map { $0! }

/// Any character other than an ASCII digit, `+` or whitespace, with common look-alikes of counts weighted up.
private let nonCountCharacter = zip(
    Gen.bool,
    Gen<Character?>.element(of: Array("-.,e!١٢５") + ["\u{301}"]).map { $0! },
    Gen.uint32(in: 0...0x10FFFF).compactMap { value -> Character? in
        guard let scalar = Unicode.Scalar(value), !("0"..."9").contains(scalar), scalar != "+",
              !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return Character(scalar)
    }
).map { $0.0 ? $0.1 : $0.2 }

/// Non-blank text that isn't ASCII digits with an optional trailing `+`.
private let nonCountText = zip(
    Gen.int(in: 0...3),
    zip(digitsAndPluses.string(of: 0...6), nonCountCharacter, digitsAndPluses.string(of: 0...6))
        .map { $0.0 + String($0.1) + $0.2 },
    zip(digitsAndPluses.string(of: 0...6), digitsAndPluses.string(of: 1...6)).map { $0.0 + "+" + $0.1 },
    zip(digitsAndPluses.string(of: 1...6), whitespace.filter { !$0.isEmpty }, digitsAndPluses.string(of: 1...6))
        .map { $0.0 + $0.1 + $0.2 }
).map { kind, withOtherCharacter, withNonTrailingPlus, withInnerWhitespace in
    [withOtherCharacter, withNonTrailingPlus, "+", withInnerWhitespace][kind]
}

struct DockBadgesTests {
    @Test func mapsApplicationURLToBundleIdentifier() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.shared", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: appURL) }

        let appID = try #require(DockBadges.appID(for: appURL), "app bundle should map to an app ID")
        #expect(appID == "com.example.shared", "app ID should be the bundle identifier")
    }

    @Test func mergesClearMissingReadAndSharedAppWindows() {
        let appID = "com.example.shared"
        let windowAppIDs = [appID, appID]
        let active = Set(windowAppIDs)

        var badges = DockBadges.merged([:], activeAppIDs: active, reads: [appID: "123"])
        #expect(windowAppIDs.map { badges[$0] } == ["99+", "99+"], "windows of one app should share its badge")

        badges = DockBadges.merged(badges, activeAppIDs: active, reads: [:])
        #expect(badges[appID] == "99+", "missing read should keep the last badge")
        badges = DockBadges.merged(badges, activeAppIDs: active, reads: ["com.example.inactive": "5"])
        #expect(badges == [appID: "99+"], "reads of inactive apps should be dropped")
        badges = DockBadges.merged(badges, activeAppIDs: active, reads: [appID: nil])
        #expect(badges[appID] == nil, "nil read should clear the badge")

        badges = DockBadges.merged(badges, activeAppIDs: active, reads: [appID: "•"])
        #expect(badges[appID] == "•", "non-count read should show a dot")
        #expect(DockBadges.merged(badges, activeAppIDs: [], reads: [:]).isEmpty, "no active apps should mean no badges")
    }

    @Test func countUpTo99ShowsAsIs() async {
        await propertyCheck(count: 1_000, input: Gen.int(in: 1...99), padding) { count, padding in
            #expect(DockBadges.displayValue(padded(String(count), padding)) == String(count), "should show as is")
        }
    }

    @Test func countOver99CapsAt99Plus() async {
        let count = zip(Gen.int(in: 100...999), Gen.number.string(of: 0...60)).map { "\($0.0)\($0.1)" }
        await propertyCheck(count: 1_000, input: count, padding) { count, padding in
            #expect(DockBadges.displayValue(padded(count, padding)) == "99+", "should cap at 99+")
        }
    }

    @Test func zeroClearsTheBadge() async {
        await propertyCheck(count: 1_000, input: Gen.int(in: 1...20), padding) { zeroCount, padding in
            let zeros = String(repeating: "0", count: zeroCount)
            #expect(DockBadges.displayValue(padded(zeros, padding)) == nil, "zero should clear the badge")
        }
    }

    @Test func negativeCountShowsADot() async {
        let count = zip(Gen.bool, Gen.int(in: -200 ... -1), Gen.int(in: Int.min ... -1)).map { $0.0 ? $0.1 : $0.2 }
        await propertyCheck(count: 1_000, input: count, padding, Gen.bool) { count, padding, plus in
            let text = padded(String(count) + (plus ? "+" : ""), padding)
            #expect(DockBadges.displayValue(text) == "•", "negative count should show a dot")
        }
    }

    @Test func countBelow99KeepsThePlus() async {
        await propertyCheck(count: 1_000, input: Gen.int(in: 1...98), padding) { count, padding in
            #expect(DockBadges.displayValue(padded("\(count)+", padding)) == "\(count)+", "should keep the +")
        }
    }

    @Test func countOf99OrMoreWithPlusCapsAt99Plus() async {
        let count = zip(Gen.int(in: 99...999), Gen.number.string(of: 0...60)).map { "\($0.0)\($0.1)" }
        await propertyCheck(count: 1_000, input: count, padding) { count, padding in
            #expect(DockBadges.displayValue(padded("\(count)+", padding)) == "99+", "should cap at 99+")
        }
    }

    @Test func badgeFitsThreeCharacters() async {
        let digits = Gen.number.string(of: 1...60)
        let text = zip(Gen.int(in: 0...2), nonCountText, digits).map { [$0.1, $0.2, $0.2 + "+"][$0.0] }
        await propertyCheck(count: 5_000, input: text, padding) { text, padding in
            let value = DockBadges.displayValue(padded(text, padding))
            #expect((value?.count ?? 0) <= 3, "badge \(value ?? "") does not fit")
        }
    }

    @Test func zeroWithPlusShowsADot() async {
        await propertyCheck(count: 1_000, input: Gen.int(in: 1...20), padding) { zeroCount, padding in
            let zeros = String(repeating: "0", count: zeroCount)
            #expect(DockBadges.displayValue(padded(zeros + "+", padding)) == "•", "0+ should show a dot")
        }
    }


    @Test func blankClearsTheBadge() async {
        await propertyCheck(count: 1_000, input: whitespace) { text in
            #expect(DockBadges.displayValue(text) == nil, "blank text should clear the badge")
        }
    }

    @Test func nonCountShowsADot() async {
        await propertyCheck(count: 5_000, input: nonCountText, padding) { text, padding in
            #expect(DockBadges.displayValue(padded(text, padding)) == "•", "text that isn't a count should show a dot")
        }
    }

    @Test func mergeOnlyKeepsBadgesOfActiveAppsAndMissingReadsKeepTheLastValue() async {
        let apps = ["a", "b", "c", "d"]
        let readOptions: [String?] = ["3", nil, "x", "0"]
        let step = zip(Gen.int(in: 0...15), Gen.int(in: 0...readOptions.count).array(of: apps.count))
        await propertyCheck(count: 500, input: step.array(of: 10)) { steps in
            var badges: [String: String] = [:]
            for (activeMask, readChoices) in steps {
                let previous = badges
                let active = Set(apps.indices.filter { activeMask & (1 << $0) != 0 }.map { apps[$0] })
                let reads: [String: String?] = Dictionary(
                    uniqueKeysWithValues: zip(apps, readChoices).compactMap { app, choice in
                        choice < readOptions.count ? (app, readOptions[choice]) : nil
                    })
                badges = DockBadges.merged(badges, activeAppIDs: active, reads: reads)
                #expect(Set(badges.keys).isSubset(of: active), "only active apps should have badges")
                for app in active {
                    switch reads[app] {
                    case let .some(raw):
                        #expect(badges[app] == raw.flatMap(DockBadges.displayValue), "read should replace the badge")
                    case nil:
                        #expect(badges[app] == previous[app], "missing read should keep the last badge")
                    }
                }
            }
        }
    }
}
