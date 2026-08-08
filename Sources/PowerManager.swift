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

    private init() {}

    // MARK: - Public API

    /// Activates lid-closed mode: prevents system sleep even when the lid is closed.
    /// Returns true if activation was successful.
    @discardableResult
    func activate() -> Bool {
        guard !isAssertionActive else { return true }

        // Step 1: Create IOKit power assertion to prevent system sleep
        let success = createPowerAssertion()

        // Step 2: Disable sleep via pmset (required for lid-close prevention)
        if success {
            disableSleep()
        }

        return success
    }

    /// Deactivates lid-closed mode: allows the system to sleep normally again.
    func deactivate() {
        // Step 1: Release IOKit power assertion
        releasePowerAssertion()

        // Step 2: Re-enable sleep via pmset
        enableSleep()
    }

    /// Returns whether lid-closed mode is currently active.
    var isActive: Bool {
        return isAssertionActive
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
            NSLog("[LidClosed] Power assertion created successfully (ID: \(assertionID))")
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

    /// Disables system sleep using pmset. This is the key mechanism for lid-close prevention.
    /// Prompts for admin credentials via AppleScript's built-in dialog.
    private func disableSleep() {
        runPrivilegedCommand("pmset disablesleep 1")
        isSleepDisabled = true
        NSLog("[LidClosed] System sleep disabled via pmset")
    }

    /// Re-enables system sleep using pmset.
    private func enableSleep() {
        guard isSleepDisabled else { return }
        runPrivilegedCommand("pmset disablesleep 0")
        isSleepDisabled = false
        NSLog("[LidClosed] System sleep re-enabled via pmset")
    }

    /// Runs a shell command with administrator privileges using AppleScript's built-in auth dialog.
    private func runPrivilegedCommand(_ command: String) {
        let script = """
        do shell script "\(command)" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[LidClosed] AppleScript error: \(error)")
            }
        }
    }

    // MARK: - Cleanup

    /// Ensures sleep is re-enabled when the app terminates.
    func cleanup() {
        deactivate()
    }

    deinit {
        cleanup()
    }
}
