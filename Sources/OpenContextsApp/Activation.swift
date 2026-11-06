import AppKit

@MainActor
enum Activation {
    /// Keeps the deprecated `activate(ignoringOtherApps:)`: its replacement `activate()` does not bring an
    /// inactive accessory app forward, which `testActivationHelpersBringAppsForwardFromTheBackground` checks.
    static func activateSelf() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The `activateIgnoringOtherApps` option is deprecated and has no effect since macOS 14.
    static func activate(_ application: NSRunningApplication) {
        if #available(macOS 14, *) {
            application.activate(options: [])
        } else {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
