import Foundation

/// Outcome of a command that required administrator authentication.
enum PrivilegedOutcome: Equatable {
    case success
    /// The user dismissed the authentication dialog. A deliberate choice, not an error.
    case cancelled
    case failed(String)
}

/// Runs a command as root. Abstracted so the activate/deactivate state machine can be
/// unit tested without triggering a real authentication dialog.
protocol PrivilegedCommandRunner: Sendable {
    @MainActor func run(command: String) -> PrivilegedOutcome
}

/// Default implementation using AppleScript's built-in authentication dialog.
struct AppleScriptPrivilegedRunner: PrivilegedCommandRunner {

    /// AppleScript's error number for "user cancelled".
    private static let userCancelledErrorNumber = -128

    @MainActor
    func run(command: String) -> PrivilegedOutcome {
        // Important: `command` is interpolated into AppleScript source. Only pass
        // hard-coded literals — never user input, a file path, or anything else that
        // could contain a quote or a backslash.
        let source = "do shell script \"\(command)\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not compile the authorization script.")
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        guard let error else { return .success }

        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if code == Self.userCancelledErrorNumber {
            return .cancelled
        }

        let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
        NSLog("[LidClosed] AppleScript error \(code): \(message)")
        return .failed(message)
    }
}
