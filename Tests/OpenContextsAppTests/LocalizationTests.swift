import Foundation
import XCTest
@testable import OpenContextsApp

final class LocalizationTests: XCTestCase {
    func testEveryLanguageHasTheSameNonEmptyKeys() throws {
        let resources = L10n.resources
        var expected: Set<String>?
        for language in AppLanguage.allCases where language != .system {
            let path = try XCTUnwrap(resources.path(forResource: language.rawValue, ofType: "lproj"), "\(language)")
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
            let entries = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String], "\(language)"
            )
            XCTAssertFalse(entries.isEmpty, "\(language)")
            XCTAssertEqual(entries.filter { $0.value.isEmpty }.keys.sorted(), [String](), "\(language)")
            if let expected { XCTAssertEqual(Set(entries.keys), expected, "\(language)") }
            XCTAssertEqual(L10n.text("Ungrouped", language: language), entries["Ungrouped"], "\(language)")
            expected = Set(entries.keys)
        }
    }

    func testEveryLanguageNamesTheAppOtherContexts() throws {
        let resources = L10n.resources
        for language in AppLanguage.allCases where language != .system {
            let path = try XCTUnwrap(resources.path(forResource: language.rawValue, ofType: "lproj"), "\(language)")
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
            let entries = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String], "\(language)"
            )
            for (key, value) in entries {
                XCTAssertFalse(key.localizedCaseInsensitiveContains("Open Contexts") || key.localizedCaseInsensitiveContains("OpenContexts"),
                               "\(language): \(key)")
                XCTAssertFalse(value.localizedCaseInsensitiveContains("Open Contexts") || value.localizedCaseInsensitiveContains("OpenContexts"),
                               "\(language): \(key) -> \(value)")
            }
            for key in ["Quit OtherContexts", "OtherContexts Settings"] {
                let value = try XCTUnwrap(entries[key], "\(language): \(key)")
                XCTAssertTrue(value.contains("OtherContexts"), "\(language): \(key) -> \(value)")
                XCTAssertEqual(L10n.text(key, language: language), value, "\(language): \(key)")
            }
        }
    }

    func testKeysMatchTheStringsUsedBySources() throws {
        let path = try XCTUnwrap(L10n.resources.path(forResource: "en", ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
        let keys = Set(try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]).keys)
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenContextsApp")
        let files = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        func literals(_ text: String) -> Set<String> {
            Set(literal.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range(at: 1)) })
        }
        XCTAssertEqual(keys.subtracting(literals(source)).sorted(), [String](), "keys not referenced by any source literal")
        let call = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\((.*?)language:"#, options: .dotMatchesLineSeparators)
        let passed = call.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .map { (source as NSString).substring(with: $0.range(at: 1)) }
            .reduce(into: Set<String>()) { $0.formUnion(literals($1)) }
        XCTAssertGreaterThan(passed.count, 0, "no L10n literals were found")
        XCTAssertEqual(passed.subtracting(keys).sorted(), [String](), "L10n literals missing from Localizable.strings")
    }

    func testLabelsUseTheTranslatedNamesOfTheElementsTheyMention() throws {
        let references = [
            ("Show New Group button", "New Group"),
            ("Show Ungrouped (hidden when empty)", "Ungrouped"),
            ("Its windows move to Ungrouped.", "Ungrouped"),
            ("＋ New Group", "New Group")
        ]
        for language in AppLanguage.allCases where language != .system {
            for (label, element) in references {
                let text = L10n.text(label, language: language)
                let name = L10n.text(element, language: language)
                XCTAssertTrue(text.localizedCaseInsensitiveContains(name), "\(language): \(label) -> \(text) lacks \(name)")
            }
        }
    }

    func testLanguageCodesResolve() {
        XCTAssertEqual(AppLanguage.en.resolvedCode, "en")
        XCTAssertEqual(AppLanguage.es.resolvedCode, "es")
        XCTAssertEqual(AppLanguage.fr.resolvedCode, "fr")
        XCTAssertEqual(AppLanguage.ja.resolvedCode, "ja")
        XCTAssertEqual(AppLanguage.zh.resolvedCode, "zh")
        XCTAssertEqual(L10n.text("Ungrouped", language: .ja), "未分類")
    }

    func testTranslationsUseTheSameFormatSpecifiersAsTheirKeys() throws {
        let resources = L10n.resources
        let specifier = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]")
        func specifiers(_ text: String) -> [String] {
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        var checked = 0
        for language in AppLanguage.allCases where language != .system {
            let path = try XCTUnwrap(resources.path(forResource: language.rawValue, ofType: "lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
            let entries = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for (key, value) in entries {
                XCTAssertEqual(specifiers(value), specifiers(key), "\(language): \(key) -> \(value)")
                checked += specifiers(key).isEmpty ? 0 : 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no format strings were checked")
        XCTAssertEqual(specifiers("%@ and %1$@ and %d%% and %.2f"), ["%%", "%.2f", "%1$@", "%@", "%d"].sorted())
    }
}
