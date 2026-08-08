import AppKit

/// Controls the macOS menu bar (status bar) icon and menu for LidClosed.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    private let powerManager = PowerManager.shared

    /// Cached system state, refreshed when the menu opens, so reading it does not spawn
    /// a `pmset` process on every UI query.
    private var isSleepDisabled = false

    private let firstRunWarningKey = "hasShownFirstTimeWarning"

    // MARK: - SF Symbols for menu bar icon

    private let iconActive = "lock.open.laptopcomputer"
    private let iconInactive = "lock.laptopcomputer"

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        refreshState()
        buildMenu()
        updateUI()
    }

    /// Re-reads the real system state and reconciles our ownership marker against it.
    /// One `pmset` invocation serves both purposes.
    private func refreshState() {
        isSleepDisabled = powerManager.syncStateWithSystem()
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: "LidClosed", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        titleItem.attributedTitle = NSAttributedString(
            string: "LidClosed",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(titleItem)

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "", action: #selector(toggleAction), keyEquivalent: "t")
        toggleMenuItem?.target = self
        // `autoenablesItems` is off, so this has to be set explicitly. The item is always
        // enabled: in the externally-managed state it opens an explanation rather than
        // changing anything.
        toggleMenuItem?.isEnabled = true
        menu.addItem(toggleMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Catches changes made outside the app, e.g. `sudo pmset disablesleep 0`.
        refreshState()
        updateUI()
    }

    // MARK: - Actions

    @objc private func toggleAction() {
        if powerManager.isOwnedByUs {
            powerManager.deactivate()
        } else if isSleepDisabled {
            // Managed outside LidClosed. `activate()` changes nothing here — it explains
            // the situation and how to hand control back. The item stays clickable so
            // that explanation is reachable instead of being a dead end.
            powerManager.activate()
        } else {
            if !UserDefaults.standard.bool(forKey: firstRunWarningKey) {
                showFirstTimeWarning()
                UserDefaults.standard.set(true, forKey: firstRunWarningKey)
            }
            powerManager.activate()
        }

        refreshState()
        updateUI()
    }

    @objc private func quitAction() {
        // The user is present, so offer an authenticated restore rather than quitting
        // silently and leaving the Mac unable to sleep. `deactivate` no-ops if we do not
        // own the override, and reports the problem itself if the restore fails.
        powerManager.deactivate(isQuitting: true)
        NSApp.terminate(nil)
    }

    private func showFirstTimeWarning() {
        let alert = NSAlert()
        alert.messageText = "System-Wide Override"
        alert.informativeText = """
        LidClosed changes a global macOS power setting that persists across reboots. If \
        you delete LidClosed while it is Active, your Mac will never sleep.

        Always disable LidClosed before deleting the app. If you forget, run this in \
        Terminal:

        sudo pmset disablesleep 0
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "I Understand")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - UI Updates

    private func updateUI() {
        updateIcon()
        statusMenuItem?.title = statusText()
        toggleMenuItem?.title = toggleText()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName = isSleepDisabled ? iconActive : iconInactive

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LidClosed") {
            image.isTemplate = true // Adapts to light/dark menu bar
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback text if SF Symbols unavailable
            button.title = isSleepDisabled ? "☕" : "💤"
        }
    }

    private func toggleText() -> String {
        if powerManager.isOwnedByUs {
            return "⏹ Disable Lid Closed Mode"
        }
        if isSleepDisabled {
            // Trailing ellipsis is the macOS convention for an item that opens a dialog.
            return "⚠ Managed Outside LidClosed…"
        }
        return "▶ Enable Lid Closed Mode"
    }

    private func statusText() -> String {
        guard isSleepDisabled else {
            return "○ Inactive — Normal sleep behavior"
        }
        return powerManager.isOwnedByUs
            ? "● Active — Managed by LidClosed"
            : "● Active — Managed by system or another app"
    }
}
