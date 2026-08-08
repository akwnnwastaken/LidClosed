import AppKit

/// Controls the macOS menu bar (status bar) icon and menu for LidClosed.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var keepAwakeMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    private let powerManager = PowerManager.shared
    private let awakeKeeper = AwakeKeeper.shared

    /// Cached system state, refreshed when the menu opens, so reading it does not spawn
    /// a `pmset` process on every UI query.
    private var isSleepDisabled = false

    private let firstRunWarningKey = "hasShownFirstTimeWarning"

    // MARK: - SF Symbols for menu bar icon

    private let iconLidClosedMode = "lock.open.laptopcomputer"
    private let iconKeepAwake = "cup.and.saucer"
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

        // `autoenablesItems` is off, so isEnabled has to be set explicitly. The lid-closed
        // item is always enabled: in the externally-managed state it opens an explanation
        // rather than changing anything.
        toggleMenuItem = NSMenuItem(title: "", action: #selector(toggleAction), keyEquivalent: "t")
        toggleMenuItem?.target = self
        toggleMenuItem?.isEnabled = true
        menu.addItem(toggleMenuItem!)

        // A checkmark item: this one is an independent option rather than a state change to
        // the system, so it reads as a setting instead of an action.
        keepAwakeMenuItem = NSMenuItem(
            title: "Keep Awake (Lid Open)",
            action: #selector(keepAwakeAction),
            keyEquivalent: "k"
        )
        keepAwakeMenuItem?.target = self
        keepAwakeMenuItem?.isEnabled = true
        menu.addItem(keepAwakeMenuItem!)

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
            // the situation and how to hand control back. The item stays clickable so that
            // explanation is reachable instead of being a dead end.
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

    /// Toggles the `caffeinate`-backed option. Independent of lid-closed mode: no password,
    /// no persistent system setting, nothing to recover.
    @objc private func keepAwakeAction() {
        if awakeKeeper.isActive {
            awakeKeeper.stop()
        } else if !awakeKeeper.start() {
            let alert = NSAlert()
            alert.messageText = "Could Not Keep the Mac Awake"
            alert.informativeText = "LidClosed could not start /usr/bin/caffeinate."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        updateUI()
    }

    @objc private func quitAction() {
        awakeKeeper.stop()

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

        If you only need the Mac awake with the lid open, use "Keep Awake" instead — it \
        needs no password and changes no system settings.
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
        keepAwakeMenuItem?.state = awakeKeeper.isActive ? .on : .off
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        if isSleepDisabled {
            symbolName = iconLidClosedMode
        } else if awakeKeeper.isActive {
            symbolName = iconKeepAwake
        } else {
            symbolName = iconInactive
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LidClosed") {
            image.isTemplate = true // Adapts to light/dark menu bar
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback text if SF Symbols unavailable
            button.image = nil
            button.title = (isSleepDisabled || awakeKeeper.isActive) ? "☕" : "💤"
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
        if isSleepDisabled {
            return powerManager.isOwnedByUs
                ? "● Active — Managed by LidClosed"
                : "● Active — Managed by system or another app"
        }
        if awakeKeeper.isActive {
            return "◐ Awake — but will sleep if the lid closes"
        }
        return "○ Inactive — Normal sleep behavior"
    }
}
