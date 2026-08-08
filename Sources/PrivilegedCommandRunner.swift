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
    @MainActor func run(executablePath: String, arguments: [String]) -> PrivilegedOutcome
}

/// Default implementation using AppleScript's built-in authentication dialog.
struct AppleScriptPrivilegedRunner: PrivilegedCommandRunner {

    /// AppleScript's error number for "user cancelled".
    private static let userCancelledErrorNumber = -128

    @MainActor
    func run(executablePath: String, arguments: [String]) -> PrivilegedOutcome {
        guard let script = NSAppleScript(source: Self.scriptSource(executablePath, arguments)) else {
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

    // MARK: - Script construction

    /// Builds the AppleScript source for running `executablePath` with `arguments` as root.
    ///
    /// The command crosses two levels of quoting — a shell command line, wrapped in an
    /// AppleScript string literal — so both are escaped here. Taking an executable and an
    /// argument array rather than a command string makes that guarantee structural: a
    /// caller cannot accidentally inject a second command, however the arguments were
    /// derived.
    static func scriptSource(_ executablePath: String, _ arguments: [String]) -> String {
        let shellCommand = ([executablePath] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")

        return "do shell script \"\(appleScriptEscaped(shellCommand))\" with administrator privileges"
    }

    /// Wraps one argument in shell single quotes. Inside single quotes every character is
    /// literal, so a single quote is the only thing needing special handling: close the
    /// quote, emit an escaped quote, reopen.
    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Escapes a string for use inside a double-quoted AppleScript literal.
    /// Backslashes must be handled before quotes, or the added escapes get re-escaped.
    static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
