import AppKit

/// Application delegate for LidClosed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController.setup()
        NSLog("[LidClosed] App launched successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Attempt a silent cleanup if we own the state.
        // If this is a forced quit, the signal handler might catch it first.
        // If it's a normal quit (e.g. from the menu), quitAction handles it.
        if PowerManager.shared.isOwnedByUs {
            PowerManager.shared.forceCleanup()
        }
    }
}
