import Foundation
import AppKit

/// Struct representing the state file contents to verify ownership
struct LidClosedState: Codable {
    let pid: Int32
    let timestamp: TimeInterval
}

/// Manages system sleep prevention using pmset.
@MainActor
final class PowerManager {
    static let shared = PowerManager()

    private let runner: CommandRunner
    
    // Keeps DispatchSource references alive
    private var signalSources: [any DispatchSourceSignal] = []

    /// File used to track whether our app activated disablesleep.
    private let stateFilePath: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LidClosed")
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()
    
    private let legacyStateFilePath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".lidclosed_active")
    }()

    // Allow injecting a test runner
    init(runner: CommandRunner = DefaultCommandRunner()) {
        self.runner = runner
        migrateLegacyStateFile()
        cleanupStaleState()
        installSignalHandlers()
    }

    // MARK: - Public API

    /// True if pmset disablesleep is currently 1 on the system.
    var isSleepDisabledSystemWide: Bool {
        do {
            let (status, output) = try runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/pmset"),
                arguments: ["-g"]
            )
            guard status == 0 else { return false }
            return output.range(of: #"SleepDisabled[ \t]+1\b"#, options: .regularExpression) != nil
        } catch {
            NSLog("[LidClosed] Failed to check pmset status: \(error)")
            return false
        }
    }
    
    /// True if we have an active state file indicating we own the disablesleep override.
    var isOwnedByUs: Bool {
        return FileManager.default.fileExists(atPath: stateFilePath.path)
    }

    /// Activates lid-closed mode: prevents system sleep.
    /// Returns true if activation was successful.
    @discardableResult
    func activate() -> Bool {
        guard !isOwnedByUs else { return true }
        
        // Disable sleep via pmset
        let success = runPrivilegedCommand("/usr/bin/pmset disablesleep 1")
        
        if success {
            writeStateFile()
            NSLog("[LidClosed] Activated sleep override successfully.")
            return true
        } else {
            NSLog("[LidClosed] Activation failed (user likely cancelled auth).")
            showAuthFailedAlert()
            return false
        }
    }

    /// Deactivates lid-closed mode.
    func deactivate() {
        guard isOwnedByUs else { return }
        
        let success = runPrivilegedCommand("/usr/bin/pmset disablesleep 0")
        if success {
            removeStateFile()
            NSLog("[LidClosed] Deactivated sleep override successfully.")
        } else {
            NSLog("[LidClosed] Deactivation failed (user likely cancelled auth).")
            showAuthFailedAlert()
        }
    }

    // MARK: - Stale State Recovery

    private func migrateLegacyStateFile() {
        if FileManager.default.fileExists(atPath: legacyStateFilePath.path) {
            writeStateFile()
            try? FileManager.default.removeItem(at: legacyStateFilePath)
            NSLog("[LidClosed] Migrated legacy state file.")
        }
    }

    /// On launch, check if a previous session crashed without cleaning up.
    private func cleanupStaleState() {
        if isOwnedByUs {
            NSLog("[LidClosed] Detected stale state from previous session. Attempting recovery...")
            if isSleepDisabledSystemWide {
                forceCleanup()
            } else {
                // pmset is 0, but we have a state file. System probably reset it, or external interference.
                // Just remove our state file.
                removeStateFile()
            }
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            // 1. Ignore default behavior immediately
            signal(sig, SIG_IGN)
            
            // 2. Setup DispatchSource
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSLog("[LidClosed] Received signal \(sig), attempting cleanup...")
                    PowerManager.shared.forceCleanup()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Silent cleanup using standard Process (no GUI auth dialog).
    /// Used during crashes or signal termination where UI is unavailable.
    func forceCleanup() {
        guard isOwnedByUs else { return }
        
        do {
            let (status, _) = try runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "do shell script \"/usr/bin/pmset disablesleep 0\" with administrator privileges"]
            )
            
            if status == 0 {
                removeStateFile()
                NSLog("[LidClosed] Force cleanup successful.")
            } else {
                NSLog("[LidClosed] Force cleanup failed (status \(status)) - state file preserved for next launch.")
            }
        } catch {
            NSLog("[LidClosed] Force cleanup error: \(error) - state file preserved for next launch.")
        }
    }

    // MARK: - Privileged Execution

    /// Runs a shell command with administrator privileges via AppleScript.
    @discardableResult
    private func runPrivilegedCommand(_ command: String) -> Bool {
        // Warning: Do not pass user input into `command` here.
        let script = """
        do shell script "\(command)" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[LidClosed] AppleScript error: \(error)")
                return false
            }
            return true
        }
        return false
    }

    // MARK: - State File Management

    private func writeStateFile() {
        let state = LidClosedState(pid: ProcessInfo.processInfo.processIdentifier, timestamp: Date().timeIntervalSince1970)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFilePath)
        } catch {
            NSLog("[LidClosed] Failed to write state file: \(error)")
        }
    }

    private func removeStateFile() {
        try? FileManager.default.removeItem(at: stateFilePath)
    }
    
    // MARK: - Alerts
    
    private func showAuthFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Authentication Failed"
        alert.informativeText = "LidClosed requires administrator privileges to modify system sleep settings. The operation was cancelled or failed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        // Ensure it comes to the front
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
