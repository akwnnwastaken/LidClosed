import AppKit

// Entry point for the LidClosed menu bar application.
@main
struct LidClosedApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
