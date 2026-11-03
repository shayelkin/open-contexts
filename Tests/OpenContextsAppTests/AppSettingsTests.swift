import Foundation
import OpenContextsCore
import XCTest
@testable import OpenContextsApp

@MainActor
final class AppSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "OpenContexts.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private var reloaded: AppSettings { AppSettings(defaults: defaults) }

    func testDesktopScopeSettingsPersistIndependently() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.showWindowsFromAllDesktops)
        settings.setShowWindowsFromAllDesktops(true)
        XCTAssertTrue(reloaded.showWindowsFromAllDesktops)
        settings.setShowWindowsFromAllDesktops(false)
        XCTAssertFalse(reloaded.showWindowsFromAllDesktops)

        XCTAssertFalse(settings.showSidebarWindowsFromAllDesktops)
        settings.setShowSidebarWindowsFromAllDesktops(true)
        XCTAssertTrue(reloaded.showSidebarWindowsFromAllDesktops)
        XCTAssertFalse(reloaded.showWindowsFromAllDesktops)
        settings.setShowSidebarWindowsFromAllDesktops(false)
        XCTAssertFalse(reloaded.showSidebarWindowsFromAllDesktops)
    }

    func testSidebarDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.sidebarMode, .always)
        XCTAssertEqual(settings.sidebarVerticalAlignment, .center)
        XCTAssertTrue(settings.showUngrouped)
        XCTAssertTrue(settings.showUngroupedTitle)
        XCTAssertTrue(settings.showCreateGroup)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.defaultSidebarWidth)
    }

    func testSidebarWidthIsClampedAndPersisted() {
        let settings = AppSettings(defaults: defaults)
        for width in [AppSettings.sidebarWidthRange.lowerBound, AppSettings.defaultSidebarWidth,
                      AppSettings.sidebarWidthRange.upperBound] {
            settings.setSidebarWidth(width)
            XCTAssertEqual(reloaded.sidebarWidth, width)
        }
        settings.setSidebarWidth(1000)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.sidebarWidthRange.upperBound)
        settings.setSidebarWidth(.nan)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.sidebarWidthRange.upperBound)
        settings.setSidebarWidth(AppSettings.defaultSidebarWidth)
        XCTAssertEqual(settings.sidebarWidth, AppSettings.defaultSidebarWidth)
        XCTAssertEqual(reloaded.sidebarWidth, AppSettings.defaultSidebarWidth)
    }

    func testStoredSidebarWidthIsSanitized() {
        defaults.set(-1.0, forKey: "sidebarWidth")
        XCTAssertEqual(reloaded.sidebarWidth, AppSettings.sidebarWidthRange.lowerBound)
        defaults.set(Double.infinity, forKey: "sidebarWidth")
        XCTAssertEqual(reloaded.sidebarWidth, AppSettings.defaultSidebarWidth)
        defaults.set("invalid", forKey: "sidebarWidth")
        XCTAssertEqual(reloaded.sidebarWidth, AppSettings.defaultSidebarWidth)
    }

    func testGroupVisibilitySettings() {
        let settings = AppSettings(defaults: defaults)
        settings.setSidebarMode(.hidden)
        settings.setSidebarVerticalAlignment(.top)
        settings.setShowUngrouped(false)
        settings.setShowCreateGroup(false)
        let hidden = reloaded
        XCTAssertEqual(hidden.sidebarMode, .hidden)
        XCTAssertEqual(hidden.sidebarVerticalAlignment, .top)
        XCTAssertFalse(hidden.showUngrouped)
        XCTAssertTrue(hidden.showUngroupedTitle)
        XCTAssertFalse(hidden.showCreateGroup)

        settings.setShowUngroupedTitle(false)
        XCTAssertFalse(reloaded.showUngroupedTitle)
        XCTAssertFalse(reloaded.showUngrouped)
        settings.setShowUngrouped(true)
        XCTAssertTrue(reloaded.showUngrouped)
        XCTAssertFalse(reloaded.showUngroupedTitle)
        settings.setShowUngroupedTitle(true)
        settings.setShowUngrouped(false)
        XCTAssertTrue(reloaded.showUngroupedTitle)

        settings.setSidebarVerticalAlignment(.bottom)
        XCTAssertEqual(reloaded.sidebarVerticalAlignment, .bottom)
        defaults.set("invalid", forKey: "sidebarVerticalAlignment")
        defaults.set("invalid", forKey: "sidebarMode")
        XCTAssertEqual(reloaded.sidebarVerticalAlignment, .center)
        XCTAssertEqual(reloaded.sidebarMode, .always)
    }

    func testSidebarPositionMigration() {
        defaults.set(16, forKey: "allWindowsKeyCode")
        defaults.set(17, forKey: "currentAppKeyCode")
        defaults.set("top", forKey: "sidebarPosition")
        XCTAssertEqual(reloaded.sidebarPosition, .right)
        XCTAssertEqual(defaults.string(forKey: "sidebarPosition"), SidebarPosition.right.rawValue)

        defaults.set("bottom", forKey: "sidebarPosition")
        defaults.set("icon", forKey: "sidebarItemDisplayMode")
        let bottom = reloaded
        XCTAssertEqual(bottom.sidebarPosition, .bottom)
        XCTAssertEqual(bottom.sidebarItemDisplayMode, .icon)
        XCTAssertEqual(defaults.string(forKey: "sidebarPosition"), SidebarPosition.bottom.rawValue)
    }

    func testLanguagePersistsAndRejectsUnsupportedValues() {
        AppSettings(defaults: defaults).setLanguage(.ja)
        XCTAssertEqual(reloaded.language, .ja)
        XCTAssertEqual(defaults.string(forKey: "language"), "ja")
        defaults.set("unsupported", forKey: "language")
        XCTAssertEqual(reloaded.language, .system)
    }

    func testShortcutsRejectConflictsAndRecoverFromCorruption() {
        defaults.set("left", forKey: "sidebarPosition")
        defaults.set("icon", forKey: "sidebarItemDisplayMode")
        let settings = AppSettings(defaults: defaults)
        let custom = KeyboardShortcut(keyCode: 16, modifiers: [.maskControl, .maskAlternate], keyLabel: "Y")
        XCTAssertEqual(settings.sidebarShortcut, .sidebar)
        XCTAssertFalse(settings.setShortcut(.sidebar, target: .allWindows))
        XCTAssertFalse(settings.setShortcut(.allWindows, target: .sidebar))
        XCTAssertTrue(settings.setShortcut(custom, target: .sidebar))
        XCTAssertEqual(reloaded.sidebarShortcut, custom)
        XCTAssertFalse(settings.setShortcut(custom, target: .currentApp))

        settings.disableSidebarShortcut()
        XCTAssertNil(settings.sidebarShortcut)
        XCTAssertNil(reloaded.sidebarShortcut)
        XCTAssertTrue(settings.setShortcut(.sidebar, target: .sidebar))
        XCTAssertEqual(reloaded.sidebarShortcut, .sidebar)
        defaults.set(Data("invalid".utf8), forKey: "sidebarShortcut")
        XCTAssertEqual(reloaded.sidebarShortcut, .sidebar)

        // Preserve an existing window shortcut that already uses the new sidebar default.
        defaults.set(try? JSONEncoder().encode(KeyboardShortcut.sidebar), forKey: "allWindowsShortcut")
        XCTAssertEqual(reloaded.allWindowsShortcut, .sidebar)
        XCTAssertNil(reloaded.sidebarShortcut)
        defaults.removeObject(forKey: "allWindowsShortcut")

        XCTAssertEqual(settings.allWindowsShortcut, .allWindows)
        XCTAssertEqual(settings.currentAppShortcut, .currentApp)
        XCTAssertFalse(settings.setShortcut(.currentApp, target: .allWindows))
        XCTAssertTrue(settings.setShortcut(custom, target: .allWindows))
        XCTAssertEqual(reloaded.allWindowsShortcut, custom)
        XCTAssertFalse(settings.setShortcut(custom, target: .currentApp))
        XCTAssertTrue(settings.setShortcut(KeyboardShortcut(keyCode: 16, modifiers: .maskCommand, keyLabel: "Y"),
                                           target: .currentApp))
        XCTAssertEqual(reloaded.currentAppShortcut.keyCode, 16)

        // Corrupt or conflicting saved values fall back to the original shortcuts.
        defaults.set(try? JSONEncoder().encode(custom), forKey: "currentAppShortcut")
        XCTAssertEqual(reloaded.allWindowsShortcut, .allWindows)
        XCTAssertEqual(reloaded.currentAppShortcut, .currentApp)
        defaults.set(Data("invalid".utf8), forKey: "allWindowsShortcut")
        XCTAssertEqual(reloaded.allWindowsShortcut, .allWindows)

        settings.resetShortcuts()
        XCTAssertEqual(reloaded.allWindowsShortcut, .allWindows)
        XCTAssertEqual(reloaded.currentAppShortcut, .currentApp)
        XCTAssertEqual(reloaded.sidebarShortcut, .sidebar)
        XCTAssertEqual(settings.sidebarPosition, .left)
        XCTAssertEqual(settings.sidebarItemDisplayMode, .icon)
        XCTAssertEqual(defaults.string(forKey: "sidebarPosition"), SidebarPosition.left.rawValue)
    }
}
