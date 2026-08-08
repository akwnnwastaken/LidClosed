import AppKit

/// Presents a modal message to the user. Abstracted so tests can assert on what the
/// user would have been told without ever opening a dialog.
protocol UserNotifier: Sendable {
    @MainActor func notify(title: String, message: String, informational: Bool)
}

/// Default implementation using `NSAlert`.
struct AlertNotifier: UserNotifier {
    @MainActor
    func notify(title: String, message: String, informational: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = informational ? .informational : .warning
        alert.addButton(withTitle: "OK")

        // A menu bar app is not frontmost, so the alert needs to be brought forward.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
