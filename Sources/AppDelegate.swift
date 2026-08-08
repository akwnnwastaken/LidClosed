import AppKit

/// Application delegate for LidClosed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Stale-state recovery can present a modal authentication dialog, so it runs here
        // with a live run loop rather than as a side effect of PowerManager's init.
        PowerManager.shared.start()

        statusBarController.setup()
        NSLog("[LidClosed] App launched successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Silent only. Quitting from the menu already offered an authenticated restore,
        // and at logout there is nobody to type a password — a second dialog here would
        // just mean two prompts for one Quit. If this fails the state file remains and
        // the next launch recovers.
        PowerManager.shared.attemptSilentRestore()
    }
}
