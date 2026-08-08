import Foundation

/// Keeps the Mac awake **while the lid is open**, by holding IOKit power assertions through a
/// `caffeinate` child process.
///
/// This is an independent option, not a replacement for lid-closed mode. IOKit assertions do
/// not prevent lid-close sleep — which is precisely why `PowerManager` uses
/// `pmset disablesleep` instead. What this path buys is that it needs no administrator
/// password and writes no persistent system setting, so none of the ownership tracking or
/// crash-recovery machinery around `PowerManager` applies here. Keep the two lifecycles
/// separate rather than generalising one over both.
@MainActor
final class AwakeKeeper {

    static let shared = AwakeKeeper()

    private static let caffeinatePath = "/usr/bin/caffeinate"

    private let launcher: BackgroundProcessLauncher
    private var process: BackgroundProcess?

    init(launcher: BackgroundProcessLauncher = DefaultBackgroundProcessLauncher()) {
        self.launcher = launcher
    }

    var isActive: Bool {
        process?.isRunning == true
    }

    /// Starts `caffeinate -dimsu -w <our pid>`.
    ///
    /// Flag notes, because each one is easy to get wrong later:
    /// - `-d` display sleep, `-i` system idle sleep, `-m` disk idle sleep, `-s` system sleep
    ///   (that last one is only honoured on AC power).
    /// - `-u` declares the user active, turning the display on if it is off. Without `-t`
    ///   this assertion expires after five seconds, so it acts as a one-shot "wake the
    ///   display now" while `-d` does the sustained work. That is intended — do not "fix" it
    ///   by adding a timeout.
    /// - `-w` ties the assertions to our pid: caffeinate releases them and exits once this
    ///   process dies. This matters more than it looks. A plain `caffeinate` child is
    ///   *orphaned* rather than reaped when its parent dies, and would hold the assertions
    ///   indefinitely; with `-w` it was verified to exit after the parent was SIGKILLed.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        let pid = ProcessInfo.processInfo.processIdentifier

        do {
            process = try launcher.launch(
                executablePath: Self.caffeinatePath,
                arguments: ["-dimsu", "-w", String(pid)]
            )
            NSLog("[LidClosed] Keep-awake started (caffeinate -w \(pid))")
            return true
        } catch {
            process = nil
            NSLog("[LidClosed] Could not start caffeinate: \(error)")
            return false
        }
    }

    /// Releases the assertions immediately. `-w` would do this on exit anyway, but an
    /// explicit stop makes switching the option off take effect at once.
    func stop() {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        NSLog("[LidClosed] Keep-awake stopped")
    }
}
