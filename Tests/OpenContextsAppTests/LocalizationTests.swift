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
