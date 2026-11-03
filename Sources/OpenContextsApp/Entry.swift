import AppKit

public enum OpenContextsMain {
    @MainActor
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
