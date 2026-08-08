import AppKit

/// Controls the macOS menu bar (status bar) icon and menu for LidClosed.
final class StatusBarController {

    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    private let powerManager = PowerManager.shared

    // MARK: - SF Symbols for menu bar icon

    private let iconActive = "lock.open.laptopcomputer"
    private let iconInactive = "lock.laptopcomputer"

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateIcon()
        buildMenu()
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
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

    // MARK: - Actions

    @objc private func toggleAction() {
        if powerManager.isActive {
            powerManager.deactivate()
        } else {
            powerManager.activate()
        }
        updateUI()
    }

    @objc private func quitAction() {
        powerManager.cleanup()
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

        let symbolName = powerManager.isActive ? iconActive : iconInactive

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LidClosed") {
            image.isTemplate = true // Adapts to light/dark menu bar
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback text if SF Symbols unavailable
            button.title = powerManager.isActive ? "☕" : "💤"
        }
    }

    private func toggleText() -> String {
        return powerManager.isActive ? "⏹ Disable Lid Closed Mode" : "▶ Enable Lid Closed Mode"
    }

    private func statusText() -> String {
        if powerManager.isActive {
            return "● Active — Mac won't sleep when lid is closed"
        } else {
            return "○ Inactive — Normal sleep behavior"
        }
    }
}
