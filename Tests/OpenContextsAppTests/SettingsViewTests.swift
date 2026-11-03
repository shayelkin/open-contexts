import AppKit
import OpenContextsCore
import SwiftUI
import XCTest
@testable import OpenContextsApp

@MainActor
final class SettingsViewTests: XCTestCase {
    func testWidthSliderAppearsOnlyOnVerticalSidebarPage() throws {
        let suite = "OpenContexts.settings-layout-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let groups = GroupStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"))
        func sliders(in view: NSView) -> [NSSlider] {
            (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        for page in SettingsPage.allCases {
            for position in SidebarPosition.allCases {
                settings.setSidebarPosition(position)
                let view = SettingsView(settings: settings, windowService: WindowService(), groupStore: groups,
                                        shortcuts: ShortcutController(), page: page)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 840, height: 600)
                host.layoutSubtreeIfNeeded()
                let controls = sliders(in: host)
                let showsWidth = page == .sidebar && position != .bottom
                XCTAssertEqual(controls.count, showsWidth ? 1 : 0, "page=\(page) position=\(position)")
                if let slider = controls.first {
                    XCTAssertEqual(slider.doubleValue, AppSettings.defaultSidebarWidth)
                    XCTAssertGreaterThan(slider.frame.width, 100)
                }
            }
        }
    }

    func testWidthSliderRoundsAndLocalizes() {
        var width = AppSettings.defaultSidebarWidth
        let view = SidebarWidthSlider(value: Binding(get: { width }, set: { width = $0 }), language: .zh)
        // The slider holds its target weakly.
        let coordinator = view.makeCoordinator()
        let slider = view.makeControl(coordinator: coordinator)
        defer { withExtendedLifetime(coordinator) {} }
        XCTAssertTrue(slider.isContinuous)
        XCTAssertEqual(slider.numberOfTickMarks, 0)
        XCTAssertEqual(slider.accessibilityLabel(), "侧边栏宽度")
        for value in [94.0, 188.4, 376.0] {
            slider.doubleValue = value
            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
            XCTAssertEqual(width, value.rounded())
        }
    }

    func testWidthSliderKnobIsCenteredOnTrack() throws {
        var width = AppSettings.defaultSidebarWidth
        let view = SidebarWidthSlider(value: Binding(get: { width }, set: { width = $0 }), language: .zh)
        let slider = view.makeControl(coordinator: view.makeCoordinator())
        slider.doubleValue = AppSettings.defaultSidebarWidth
        slider.appearance = NSAppearance(named: .aqua)
        for height in [20.0, 28.0] {
            slider.frame = NSRect(x: 0, y: 0, width: 400, height: height)
            let bitmap = try XCTUnwrap(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
            let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
            slider.cacheDisplay(in: slider.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / slider.bounds.width
            func blueCenter(at x: CGFloat) -> Double? {
                let rows = (0..<bitmap.pixelsHigh).filter { y in
                    guard let color = bitmap.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB) else { return false }
                    return color.blueComponent > 0.8 && color.redComponent < 0.5 && color.greenComponent < 0.75
                }
                guard let first = rows.first, let last = rows.last else { return nil }
                return Double(first + last) / 2
            }
            let trackCenter = try XCTUnwrap(blueCenter(at: 30), "height=\(height)")
            let knobCenter = try XCTUnwrap(blueCenter(at: cell.knobRect(flipped: slider.isFlipped).midX), "height=\(height)")
            XCTAssertLessThanOrEqual(abs(trackCenter - knobCenter), 1, "height=\(height)")
        }
    }
}
