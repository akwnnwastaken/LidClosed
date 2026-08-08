import AppKit

/// Application delegate for LidClosed.
/// Handles app lifecycle events and ensures clean shutdown.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — this is a menu bar-only app
        NSApp.setActivationPolicy(.accessory)

        // Set up the status bar icon and menu
        statusBarController.setup()

        NSLog("[LidClosed] App launched successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Critical: re-enable sleep before quitting
        PowerManager.shared.cleanup()
        NSLog("[LidClosed] App terminated, sleep re-enabled")
    }

    /// Handle system sleep/wake notifications
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PowerManager.shared.cleanup()
        return .terminateNow
    }
}
