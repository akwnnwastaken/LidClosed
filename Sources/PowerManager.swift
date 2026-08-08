import Foundation
import IOKit
import IOKit.pwr_mgt

/// Manages macOS power assertions and system sleep prevention.
/// Uses both IOKit assertions and pmset to reliably prevent sleep when the lid is closed.
final class PowerManager {

    static let shared = PowerManager()

    private var assertionID: IOPMAssertionID = 0
    private var isAssertionActive = false
    private var isSleepDisabled = false

    /// File used to track whether disablesleep is active across sessions.
    /// If the app crashes, next launch will detect this and clean up.
    private let stateFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.lidclosed_active"
    }()

    private init() {
        cleanupStaleState()
        installSignalHandlers()
    }

    // MARK: - Public API

    /// Activates lid-closed mode: prevents system sleep even when the lid is closed.
    /// Returns true if activation was successful.
    @discardableResult
    func activate() -> Bool {
        guard !isAssertionActive else { return true }

        // Step 1: Create IOKit power assertion to prevent idle system sleep
        let assertionOk = createPowerAssertion()

        // Step 2: Disable sleep via pmset (this is the critical part for lid-close)
        let pmsetOk = disableSleep()

        if assertionOk && pmsetOk {
            writeStateFile()
            return true
        } else if assertionOk && !pmsetOk {
            // IOKit assertion alone won't prevent lid-close sleep.
            // User probably cancelled the password dialog.
            releasePowerAssertion()
            return false
        }

        return false
    }

    /// Deactivates lid-closed mode: allows the system to sleep normally again.
    func deactivate() {
        releasePowerAssertion()
        enableSleep()
        removeStateFile()
    }

    /// Returns whether lid-closed mode is currently active.
    var isActive: Bool {
        return isAssertionActive && isSleepDisabled
    }

    // MARK: - Stale State Recovery

    /// On launch, check if a previous session crashed without cleaning up.
    /// If so, re-enable sleep immediately.
    private func cleanupStaleState() {
        if FileManager.default.fileExists(atPath: stateFilePath) {
            NSLog("[LidClosed] Detected stale state from previous crash — re-enabling sleep")
            // Run non-privileged check first to see if disablesleep is actually set
            if isDisableSleepActive() {
                // Force re-enable without tracking state
                runPrivilegedCommand("pmset disablesleep 0")
            }
            removeStateFile()
        }
    }

    /// Checks current pmset settings to see if disablesleep is active.
    private func isDisableSleepActive() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("SleepDisabled           1")
            }
        } catch {
            NSLog("[LidClosed] Failed to check pmset status: \(error)")
        }
        return false
    }

    // MARK: - Signal Handlers

    /// Install handlers for SIGTERM, SIGINT, SIGHUP to ensure cleanup on forced termination.
    private func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signal in
            NSLog("[LidClosed] Received signal \(signal), cleaning up...")
            PowerManager.shared.forceCleanup()
            exit(0)
        }

        signal(SIGTERM, handler)
        signal(SIGINT, handler)
        signal(SIGHUP, handler)
    }

    /// Emergency cleanup that doesn't check internal state — just force re-enables sleep.
    func forceCleanup() {
        // Release IOKit assertion if we have one
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }

        // Force re-enable sleep via a direct Process call (no AppleScript, no auth dialog)
        // This uses the cached admin credentials if available
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"pmset disablesleep 0\" with administrator privileges"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[LidClosed] Force cleanup failed: \(error)")
        }

        removeStateFile()
    }

    // MARK: - IOKit Power Assertions

    private func createPowerAssertion() -> Bool {
        let reasonForActivity = "LidClosed: Preventing system sleep with lid closed" as CFString

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonForActivity,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isAssertionActive = true
            NSLog("[LidClosed] Power assertion created (ID: \(assertionID))")
            return true
        } else {
            NSLog("[LidClosed] Failed to create power assertion: \(result)")
            return false
        }
    }

    private func releasePowerAssertion() {
        guard isAssertionActive else { return }

        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            isAssertionActive = false
            assertionID = 0
            NSLog("[LidClosed] Power assertion released")
        } else {
            NSLog("[LidClosed] Failed to release power assertion: \(result)")
        }
    }

    // MARK: - pmset Sleep Control

    /// Disables system sleep using pmset. Returns true if successful.
    @discardableResult
    private func disableSleep() -> Bool {
        let success = runPrivilegedCommand("pmset disablesleep 1")
        if success {
            isSleepDisabled = true
            NSLog("[LidClosed] System sleep disabled via pmset")
        } else {
            NSLog("[LidClosed] Failed to disable sleep (user may have cancelled)")
        }
        return success
    }

    /// Re-enables system sleep using pmset.
    private func enableSleep() {
        guard isSleepDisabled else { return }
        runPrivilegedCommand("pmset disablesleep 0")
        isSleepDisabled = false
        NSLog("[LidClosed] System sleep re-enabled via pmset")
    }

    /// Runs a shell command with administrator privileges using AppleScript's built-in auth dialog.
    /// Returns true if the command executed without errors.
    @discardableResult
    private func runPrivilegedCommand(_ command: String) -> Bool {
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
        FileManager.default.createFile(
            atPath: stateFilePath,
            contents: "active".data(using: .utf8)
        )
    }

    private func removeStateFile() {
        try? FileManager.default.removeItem(atPath: stateFilePath)
    }

    // MARK: - Cleanup

    /// Ensures sleep is re-enabled when the app terminates normally.
    func cleanup() {
        deactivate()
    }

    deinit {
        cleanup()
    }
}
