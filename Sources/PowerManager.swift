import Foundation

/// Contents of the state file, recording that *we* enabled the system sleep override.
struct LidClosedState: Codable, Equatable {
    let pid: Int32
    let timestamp: TimeInterval
}

/// Manages system sleep prevention using `pmset disablesleep`.
///
/// Two questions are kept deliberately separate:
/// - `isSleepDisabledSystemWide` — what the system actually reports right now.
/// - `isOwnedByUs` — whether *this app* is the one that disabled it.
///
/// Only overrides we own are ever turned back off, so LidClosed never clobbers a
/// setting someone else configured.
@MainActor
final class PowerManager {

    static let shared = PowerManager()

    private let runner: CommandRunner
    private let privilegedRunner: PrivilegedCommandRunner
    private let notifier: UserNotifier
    private let stateFileURL: URL

    /// Keeps DispatchSource references alive.
    private var signalSources: [any DispatchSourceSignal] = []
    private var didStart = false

    private static let pmsetPath = "/usr/bin/pmset"

    // MARK: - Initialization

    /// Default state file location: `~/Library/Application Support/LidClosed/state.json`
    ///
    /// `nonisolated` so it can be used as a default argument value for `init`.
    nonisolated static func defaultStateFileURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent("LidClosed", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private static let legacyStateFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".lidclosed_active")

    /// Pure initializer — no filesystem writes, no signal handlers, no recovery.
    /// All launch-time side effects live in `start()` so that tests can construct an
    /// instance without touching the real system or the user's real state file.
    init(runner: CommandRunner = DefaultCommandRunner(),
         privilegedRunner: PrivilegedCommandRunner = AppleScriptPrivilegedRunner(),
         notifier: UserNotifier = AlertNotifier(),
         stateFileURL: URL = PowerManager.defaultStateFileURL()) {
        self.runner = runner
        self.privilegedRunner = privilegedRunner
        self.notifier = notifier
        self.stateFileURL = stateFileURL
    }

    /// Performs launch-time work: legacy migration, stale-state recovery and signal
    /// handler installation.
    ///
    /// Call this once from `applicationDidFinishLaunching` — never from `init`. Recovery
    /// can present a modal authentication dialog, which needs a running run loop, and
    /// installing process-wide signal handlers must not be a side effect of merely
    /// constructing an object.
    func start() {
        guard !didStart else { return }
        didStart = true

        migrateLegacyStateFile()
        recoverStaleState()
        installSignalHandlers()
    }

    // MARK: - System State

    /// True if `pmset` currently reports that sleep is disabled, regardless of who did it.
    var isSleepDisabledSystemWide: Bool {
        do {
            let (status, output) = try runner.run(
                executableURL: URL(fileURLWithPath: Self.pmsetPath),
                arguments: ["-g"]
            )
            guard status == 0 else {
                NSLog("[LidClosed] pmset -g exited with status \(status)")
                return false
            }
            return output.range(of: #"SleepDisabled[ \t]+1\b"#, options: .regularExpression) != nil
        } catch {
            NSLog("[LidClosed] Failed to check pmset status: \(error)")
            return false
        }
    }

    /// True if a state file is present, meaning we (or a previous session of ours)
    /// enabled the override.
    ///
    /// Presence alone is the test, on purpose: an unreadable or truncated file still
    /// means a previous session disabled sleep, and attempting recovery is safer than
    /// skipping it.
    var isOwnedByUs: Bool {
        FileManager.default.fileExists(atPath: stateFileURL.path)
    }

    /// Drops our ownership marker if the system no longer has sleep disabled — for
    /// example after the user ran `sudo pmset disablesleep 0` in Terminal.
    ///
    /// - Returns: the system state that was just read, so callers can reuse it instead of
    ///   spawning a second `pmset`.
    @discardableResult
    func syncStateWithSystem() -> Bool {
        let isDisabled = isSleepDisabledSystemWide

        if isOwnedByUs && !isDisabled {
            NSLog("[LidClosed] Sleep was re-enabled outside LidClosed — clearing our state file")
            removeStateFile()
        }

        return isDisabled
    }

    // MARK: - Activation

    /// Disables system sleep, including lid-close sleep.
    @discardableResult
    func activate() -> Bool {
        guard !isOwnedByUs else { return true }

        // Never claim an override we did not create. Otherwise a later Disable would
        // turn off a setting the user (or another app) configured deliberately.
        if isSleepDisabledSystemWide {
            NSLog("[LidClosed] Sleep already disabled by something else — not taking ownership")
            notifier.notify(
                title: "Sleep Is Already Disabled",
                message: """
                System sleep is currently disabled by something other than LidClosed — \
                either a manual `pmset` command or another app.

                LidClosed left the setting untouched so it will not override a \
                configuration it did not create. To manage it from here, first run:

                sudo pmset disablesleep 0
                """,
                informational: true
            )
            return false
        }

        switch privilegedRunner.run(executablePath: Self.pmsetPath, arguments: ["disablesleep", "1"]) {
        case .success:
            NSLog("[LidClosed] Sleep override enabled")
            if !writeStateFile() {
                // Sleep is off but we cannot track it, so automatic restore is impossible.
                // The user must be told, or the Mac silently never sleeps again.
                notifier.notify(
                    title: "Sleep Disabled, But Not Tracked",
                    message: """
                    LidClosed disabled system sleep but could not write its state file, so \
                    it cannot restore sleep automatically.

                    When you are done, run this in Terminal:

                    sudo pmset disablesleep 0
                    """,
                    informational: false
                )
            }
            return true

        case .cancelled:
            // Nothing changed, and the menu already shows "Inactive". No alert needed.
            NSLog("[LidClosed] Activation cancelled by user")
            return false

        case .failed(let message):
            NSLog("[LidClosed] Activation failed: \(message)")
            notifier.notify(
                title: "Could Not Disable Sleep",
                message: "LidClosed could not change the system sleep setting.\n\n\(message)",
                informational: false
            )
            return false
        }
    }

    /// Re-enables system sleep, if and only if we are the ones who disabled it.
    ///
    /// On failure the state file is deliberately kept, so the next launch can recover.
    /// - Parameter isQuitting: tailors the failure message for an app that is about to exit.
    @discardableResult
    func deactivate(isQuitting: Bool = false) -> Bool {
        guard isOwnedByUs else { return true }

        switch privilegedRunner.run(executablePath: Self.pmsetPath, arguments: ["disablesleep", "0"]) {
        case .success:
            removeStateFile()
            NSLog("[LidClosed] Sleep override removed")
            return true

        case .cancelled:
            NSLog("[LidClosed] Deactivation cancelled — sleep is still disabled, state file kept")
            notifyStillDisabled(isQuitting: isQuitting, detail: nil)
            return false

        case .failed(let message):
            NSLog("[LidClosed] Deactivation failed: \(message) — state file kept")
            notifyStillDisabled(isQuitting: isQuitting, detail: message)
            return false
        }
    }

    /// Best-effort restore with no user interaction, for SIGTERM/logout and app
    /// termination where presenting an authentication dialog is impossible.
    ///
    /// Without root this call fails, and that is expected: the state file is kept on
    /// failure so the next launch prompts and recovers.
    func attemptSilentRestore() {
        guard isOwnedByUs else { return }

        do {
            let (status, _) = try runner.run(
                executableURL: URL(fileURLWithPath: Self.pmsetPath),
                arguments: ["disablesleep", "0"]
            )
            if status == 0 {
                removeStateFile()
                NSLog("[LidClosed] Silent restore succeeded")
            } else {
                NSLog("[LidClosed] Silent restore failed (status \(status)) — state file kept for next-launch recovery")
            }
        } catch {
            NSLog("[LidClosed] Silent restore could not run: \(error) — state file kept for next-launch recovery")
        }
    }

    private func notifyStillDisabled(isQuitting: Bool, detail: String?) {
        let lead = isQuitting
            ? "LidClosed is quitting, but system sleep is still disabled — your Mac will not sleep."
            : "System sleep is still disabled — your Mac will not sleep."

        var message = """
        \(lead)

        Relaunch LidClosed to try again, or run this in Terminal:

        sudo pmset disablesleep 0
        """

        if let detail {
            message += "\n\n(\(detail))"
        }

        notifier.notify(title: "Sleep Is Still Disabled", message: message, informational: false)
    }

    // MARK: - Stale State Recovery

    /// Moves a pre-1.1 marker from `~/.lidclosed_active` to the current location, so an
    /// override left behind by an older build is still recoverable.
    private func migrateLegacyStateFile() {
        let legacy = Self.legacyStateFileURL
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        if !isOwnedByUs {
            // The legacy file carries no metadata, so record a zero pid: it marks an
            // override owned by a process that is definitively gone.
            writeStateFile(state: LidClosedState(pid: 0, timestamp: Date().timeIntervalSince1970))
        }
        try? FileManager.default.removeItem(at: legacy)
        NSLog("[LidClosed] Migrated legacy state file")
    }

    /// A state file at launch means a previous session never restored sleep.
    private func recoverStaleState() {
        guard isOwnedByUs else { return }

        if let state = readState() {
            let age = Int(Date().timeIntervalSince1970 - state.timestamp)
            let owner = state.pid == 0
                ? "an older build"
                : "pid \(state.pid) (\(isProcessAlive(state.pid) ? "still running" : "gone"))"
            NSLog("[LidClosed] Found state file from \(owner), \(age)s old")
        } else {
            NSLog("[LidClosed] State file present but unreadable — treating it as stale")
        }
        // Process liveness is logged for diagnosis only, never used to skip recovery:
        // pids are recycled, and wrongly skipping recovery leaves the Mac unable to sleep.

        guard isSleepDisabledSystemWide else {
            NSLog("[LidClosed] Sleep is already enabled — clearing stale state file")
            removeStateFile()
            return
        }

        NSLog("[LidClosed] Stale override detected — re-enabling system sleep")
        switch privilegedRunner.run(executablePath: Self.pmsetPath, arguments: ["disablesleep", "0"]) {
        case .success:
            removeStateFile()
            NSLog("[LidClosed] Recovery complete")
        case .cancelled:
            NSLog("[LidClosed] Recovery declined by user — state file kept")
        case .failed(let message):
            NSLog("[LidClosed] Recovery failed: \(message) — state file kept")
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            // Ignore the default disposition first, so the process cannot be killed in
            // the window before the DispatchSource is armed.
            signal(sig, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    NSLog("[LidClosed] Received signal \(sig) — attempting silent restore")
                    // No authentication dialog here: at logout there is nobody to type a
                    // password, and blocking on one would just get the process killed.
                    self?.attemptSilentRestore()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - State File

    @discardableResult
    private func writeStateFile() -> Bool {
        writeStateFile(state: LidClosedState(
            pid: ProcessInfo.processInfo.processIdentifier,
            timestamp: Date().timeIntervalSince1970
        ))
    }

    @discardableResult
    private func writeStateFile(state: LidClosedState) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: stateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: stateFileURL, options: .atomic)
            return true
        } catch {
            NSLog("[LidClosed] Failed to write state file: \(error)")
            return false
        }
    }

    private func readState() -> LidClosedState? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        return try? JSONDecoder().decode(LidClosedState.self, from: data)
    }

    private func removeStateFile() {
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    /// Probes for a process without sending it a signal.
    private func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
