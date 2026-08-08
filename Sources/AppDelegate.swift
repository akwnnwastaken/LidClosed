import AppKit

/// Application delegate for LidClosed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBarController = StatusBarController()
    private let instanceLock = InstanceLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Must come before start(): a second instance would see the first one's live state
        // file, treat the override as stale, and try to undo it.
        guard instanceLock.tryAcquire() else {
            NSLog("[LidClosed] Another instance is already running — exiting")
            reportDuplicateInstance()

            // exit() rather than NSApp.terminate(), so applicationWillTerminate does not run
            // and touch state that belongs to the instance that actually holds the lock.
            exit(0)
        }

        // Stale-state recovery can present a modal authentication dialog, so it runs here
        // with a live run loop rather than as a side effect of PowerManager's init.
        PowerManager.shared.start()

        statusBarController.setup()
        NSLog("[LidClosed] App launched successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // caffeinate would release its assertions on our exit anyway thanks to `-w`, but
        // stopping explicitly makes it immediate.
        AwakeKeeper.shared.stop()

        // Silent only. Quitting from the menu already offered an authenticated restore,
        // and at logout there is nobody to type a password — a second dialog here would
        // just mean two prompts for one Quit. If this fails the state file remains and
        // the next launch recovers.
        PowerManager.shared.attemptSilentRestore()
    }

    /// Launch Services normally activates the running instance instead of starting a second
    /// process, so in practice this is only reached when the executable is launched directly
    /// — which is exactly the case where silently exiting would be baffling.
    private func reportDuplicateInstance() {
        let alert = NSAlert()
        alert.messageText = "LidClosed Is Already Running"
        alert.informativeText = "Look for the laptop icon in the menu bar. This second copy will now quit."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
