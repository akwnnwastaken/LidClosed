import AppKit
import SwiftUI

/// Owns the menu bar popover and keeps its presentation in sync with both modes.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let panel = PanelState()
    private var monitor: (any DispatchSourceTimer)?
    private var lidSession: (limits: SessionLimits, deadline: Date?)?
    private var awakeStopReason: String?
    private var isTogglingLid = false
    private var supportsLidLimits = false

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

        popover.behavior = .transient
        let hosting = NSHostingController(rootView: LidClosedPanel(
            panel: panel,
            toggle: { [weak self] mode in
                if mode == .lidClosed { self?.toggleAction() } else { self?.keepAwakeAction() }
            },
            save: { [weak self] in self?.saveLimits($0, for: $1) },
            quit: { [weak self] in self?.quitAction() }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)

        refreshState()
        updateUI()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitorSessions(refreshSystem: true)
            }
        }
    }

    /// Re-reads the real system state and reconciles our ownership marker against it.
    /// One `pmset` invocation serves both purposes.
    private func refreshState() {
        isSleepDisabled = powerManager.syncStateWithSystem()
        if !powerManager.isOwnedByUs { lidSession = nil }
    }

    private func monitorSessions(refreshSystem: Bool = false) {
        if !isTogglingLid && (refreshSystem || powerManager.isOwnedByUs) {
            refreshState()
        }
        if let reason = awakeKeeper.enforceLimits() {
            awakeStopReason = reason
        }
        updateUI()
    }

    private func updateMonitor() {
        if powerManager.isOwnedByUs || awakeKeeper.isActive {
            guard monitor == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.monitorSessions() }
            }
            monitor = timer
            timer.resume()
        } else {
            monitor?.cancel()
            monitor = nil
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        supportsLidLimits = powerManager.supportsSessionLimits
        monitorSessions(refreshSystem: true)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func savedLimits(for mode: PanelMode) -> SessionLimits {
        guard let data = UserDefaults.standard.data(forKey: mode.defaultsKey),
              let limits = try? JSONDecoder().decode(SessionLimits.self, from: data),
              limits.isValid, limits.battery >= mode.minimumBattery
        else { return mode.defaultLimits }
        return limits
    }

    private func saveLimits(_ limits: SessionLimits, for mode: PanelMode) {
        guard limits.isValid, limits.battery >= mode.minimumBattery,
              let data = try? JSONEncoder().encode(limits)
        else { return }
        UserDefaults.standard.set(data, forKey: mode.defaultsKey)
        if mode == .keepAwake { awakeStopReason = nil }
        updateUI()
    }

    // MARK: - Actions

    private func toggleAction() {
        guard !isTogglingLid else { return }
        popover.performClose(nil)
        refreshState()
        isTogglingLid = true
        defer {
            isTogglingLid = false
            monitorSessions(refreshSystem: true)
        }

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
            let limits = savedLimits(for: .lidClosed)
            if powerManager.activate(limits: limits) {
                lidSession = (limits, limits.deadline())
            }
        }
    }

    /// Toggles the `caffeinate`-backed option. Independent of lid-closed mode: no password,
    /// no persistent system setting, nothing to recover.
    private func keepAwakeAction() {
        awakeStopReason = nil
        if awakeKeeper.isActive {
            awakeKeeper.stop()
        } else {
            awakeKeeper.start(limits: savedLimits(for: .keepAwake))
        }

        updateUI()
    }

    private func quitAction() {
        guard !isTogglingLid else { return }
        popover.performClose(nil)
        refreshState()
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
        let lidLimits = savedLimits(for: .lidClosed)
        let awakeLimits = savedLimits(for: .keepAwake)
        let lidActive = powerManager.isOwnedByUs
        let awakeActive = awakeKeeper.isActive
        let external = isSleepDisabled && !lidActive
        let next = PanelState.Snapshot(
            status: String(statusText().dropFirst(2)),
            lid: .init(active: lidActive, saved: lidLimits,
                       summary: Self.summary(lidSession?.limits ?? lidLimits, deadline: lidSession?.deadline),
                       availability: supportsLidLimits ? nil : "Install the background guard to use custom limits.",
                       managedExternally: external),
            awake: .init(active: awakeActive, saved: awakeLimits,
                         summary: awakeActive ? Self.summary(awakeKeeper.limits, deadline: awakeKeeper.deadline)
                             : (awakeStopReason ?? Self.summary(awakeLimits)))
        )
        if panel.snapshot != next { panel.snapshot = next }
        updateMonitor()
    }

    private static func summary(_ limits: SessionLimits, deadline: Date? = nil) -> String {
        var parts: [String] = []
        if let deadline {
            parts.append(deadline <= .now ? "Time limit reached" : "Until \(deadline.formatted(date: .omitted, time: .shortened))")
        } else if limits.minutes > 0 {
            parts.append("\(limits.minutes) min")
        }
        if limits.heat != .off { parts.append("\(limits.heat.title) heat") }
        if limits.battery > 0 { parts.append("Battery ≤ \(limits.battery)%") }
        return parts.isEmpty ? "Until turned off" : parts.joined(separator: " · ")
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

        button.setAccessibilityLabel("LidClosed. \(statusText())")
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true // Adapts to light/dark menu bar
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
            button.title = ""
        } else {
            // Fallback text if SF Symbols unavailable
            button.image = nil
            button.title = "LidClosed"
        }
    }

    private func statusText() -> String {
        Self.statusText(
            isSleepDisabled: isSleepDisabled,
            isOwnedByUs: powerManager.isOwnedByUs,
            isKeepingAwake: awakeKeeper.isActive
        )
    }

    /// Describes the combined effect of both switches.
    ///
    /// The two mechanisms cover different things, so the line names both.
    ///
    /// `pmset disablesleep 1` does **not** hold the display on: locking the screen with only
    /// lid-closed mode active turns the display off, while locking it with only Keep Awake
    /// active does not. Do not try to settle this with an idle-timeout test — see the
    /// `UserIsActive` trap in AGENTS.md.
    ///
    /// Pure and `static` so every combination can be tested.
    static func statusText(isSleepDisabled: Bool, isOwnedByUs: Bool, isKeepingAwake: Bool) -> String {
        guard isSleepDisabled else {
            return isKeepingAwake
                ? "◐ Awake — but sleeps if you close the lid"
                : "○ Inactive — normal sleep behavior"
        }

        let lead = isOwnedByUs
            ? "● Awake with the lid closed"
            : "● Sleep disabled outside LidClosed"

        return isKeepingAwake
            ? "\(lead) — display stays on too"
            : "\(lead) — display can still turn off"
    }
}
