import AppKit

/// Controls the macOS menu bar (status bar) icon and menu for LidClosed.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    private let powerManager = PowerManager.shared
    
    // Cached state to prevent spamming pmset
    private var currentSystemState: Bool = false

    // MARK: - SF Symbols for menu bar icon

    private let iconActive = "lock.open.laptopcomputer"
    private let iconInactive = "lock.laptopcomputer"

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Initial state load
        refreshState()
        buildMenu()
    }
    
    // Refresh cached state from pmset
    private func refreshState() {
        powerManager.syncStateWithSystem()
        currentSystemState = powerManager.isSleepDisabledSystemWide
        updateIcon()
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // App title
        let titleItem = NSMenuItem(title: "LidClosed", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        if let font = NSFont.boldSystemFont(ofSize: 13) as NSFont? {
            titleItem.attributedTitle = NSAttributedString(
                string: "LidClosed",
                attributes: [.font: font]
            )
        }
        menu.addItem(titleItem)

        // Status indicator
        statusMenuItem = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        menu.addItem(NSMenuItem.separator())

        // Toggle button
        toggleMenuItem = NSMenuItem(
            title: toggleText(),
            action: #selector(toggleAction),
            keyEquivalent: "t"
        )
        toggleMenuItem?.target = self
        menu.addItem(toggleMenuItem!)

        menu.addItem(NSMenuItem.separator())

        // Quit button
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh state when user opens menu to catch external changes
        refreshState()
        updateUI()
    }

    // MARK: - Actions

    @objc private func toggleAction() {
        // We act based on whether WE own the state, not the system state
        if powerManager.isOwnedByUs {
            powerManager.deactivate()
        } else {
            // First time activation warning check could go here, but let's just activate
            // We show alert in PowerManager if auth fails.
            if !UserDefaults.standard.bool(forKey: "hasShownFirstTimeWarning") {
                showFirstTimeWarning()
                UserDefaults.standard.set(true, forKey: "hasShownFirstTimeWarning")
            }
            powerManager.activate()
        }
        
        // Refresh after action
        refreshState()
        updateUI()
    }
    
    private func showFirstTimeWarning() {
        let alert = NSAlert()
        alert.messageText = "System-Wide Override"
        alert.informativeText = "LidClosed changes a global macOS power setting. If you uninstall LidClosed while it is Active, your Mac will never sleep.\n\nAlways Disable LidClosed before deleting the app. If you forget, run this in Terminal:\nsudo pmset disablesleep 0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "I Understand")
        
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitAction() {
        // Only cleanup if WE own it
        if powerManager.isOwnedByUs {
            powerManager.forceCleanup() // silent attempt
        }
        NSApp.terminate(nil)
    }

    // MARK: - UI Updates

    private func updateUI() {
        updateIcon()
        toggleMenuItem?.title = toggleText()
        statusMenuItem?.title = statusText()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName = currentSystemState ? iconActive : iconInactive

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LidClosed") {
            image.isTemplate = true // Adapts to light/dark menu bar
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback text if SF Symbols unavailable
            button.title = currentSystemState ? "☕" : "💤"
        }
    }

    private func toggleText() -> String {
        return powerManager.isOwnedByUs ? "⏹ Disable Lid Closed Mode" : "▶ Enable Lid Closed Mode"
    }

    private func statusText() -> String {
        if currentSystemState {
            if powerManager.isOwnedByUs {
                return "● Active — Managed by LidClosed"
            } else {
                return "● Active — Managed by System/Other App"
            }
        } else {
            return "○ Inactive — Normal sleep behavior"
        }
    }
}
