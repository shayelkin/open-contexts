import Foundation
import XCTest
@testable import OpenContextsApp

final class LocalizationTests: XCTestCase {
    func testEveryLanguageHasTheSameNonEmptyKeys() throws {
        let resources = try XCTUnwrap(L10n.resources)
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
}
