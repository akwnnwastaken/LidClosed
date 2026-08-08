# LidClosed: Code Review Remediation

This document tracks what was actually changed in response to the 25-point code review,
and — just as importantly — what the limits of those changes are.

## 1. Privilege escalation

The app runs `pmset` as root through an AppleScript administrator prompt. The original
install script copied the bundle to `/Applications` with `cp -R`, leaving it owned by the
logged-in user. Any process running as that user could therefore replace the executable
and inherit root the next time the user typed their admin password.

**What was done:**

- **Root ownership (the actual fix).** `scripts/install.sh` now stages the bundle, applies
  `chown -R root:wheel` and `chmod -R go-w`, then swaps it into place. Writing to the
  bundle now requires root, which removes the escalation path.
- **Ad-hoc signing (integrity signal only).** The bundle is signed with
  `codesign --force --options runtime -s -` and verified with `--verify --strict`.

> [!WARNING]
> Ad-hoc signing is **not** a security boundary. Anyone can produce a valid ad-hoc
> signature without a certificate — replace the binary, re-sign, and `codesign --verify`
> reports "valid on disk / satisfies its Designated Requirement" again. This was verified
> experimentally. Signing catches accidental corruption; **root ownership** is what stops
> an attacker.

Two gaps remain by design:

- The unsigned-ownership copy left in `dist/` is fully launchable and is owned by the
  user. Running that copy reopens the escalation path.
- Installing by hand with `cp -R` instead of the script produces a user-owned bundle.
  The script prints a warning about both cases.

Proper mitigation beyond this would mean a privileged helper installed via
`SMAppService` with a code requirement check. That is deliberately out of scope.

## 2. State machine and recovery

The old code tracked one boolean for two different questions, and leaked state whenever a
privileged command failed.

**What was done:**

- **IOKit assertions removed entirely.** `pmset disablesleep 1` already prevents both idle
  sleep and lid-close sleep, so the second mechanism was redundant — and requiring both to
  agree was the direct cause of the worst bug (sleep left disabled with no recovery marker
  and no way to switch it off from the UI).
- **Ownership separated from system state.** `isSleepDisabledSystemWide` reads
  `/usr/bin/pmset -g`; `isOwnedByUs` checks for our state file. The app only ever turns off
  an override it created.
- **External overrides are never claimed.** If sleep is already disabled by a manual
  `pmset` or another app, `activate()` runs no command, explains the situation, and the
  menu shows the toggle disabled with "Managed Outside LidClosed".
- **Failures preserve the recovery marker.** A cancelled or failed disable keeps
  `state.json` so the next launch can recover, and tells the user sleep is still disabled.
- **Failed state-file writes are surfaced.** If sleep is disabled but the marker cannot be
  written, automatic restore is impossible, so the user is told explicitly.
- **Migration.** A pre-existing `~/.lidclosed_active` marker is migrated to
  `~/Library/Application Support/LidClosed/state.json`, so an override left by an older
  build is still recoverable.
- **Metadata is read, not just written.** `state.json` carries the owning pid and a
  timestamp, and recovery logs both plus whether that process is still alive. Liveness is
  logged for diagnosis only and never used to skip recovery — pids get recycled, and
  wrongly skipping recovery would leave the Mac unable to sleep.

## 3. Termination and signal handling

**What was done:**

- **Interactive and silent teardown are now separate operations.**
  `deactivate()` prompts for authorization and is used by the menu's Disable and Quit
  items, where the user is present. `attemptSilentRestore()` runs `/usr/bin/pmset` directly
  with no dialog and is used by the signal handlers and `applicationWillTerminate`.
- **The double password prompt on Quit is gone.** Quit performs one authenticated attempt;
  `applicationWillTerminate` only ever runs the silent path.
- **Signal handler ordering fixed.** `signal(sig, SIG_IGN)` is installed before the
  `DispatchSource` is armed, closing the window in which the default disposition could
  still kill the process.
- **Recovery no longer runs during static initialization.** `PowerManager.init` is pure;
  migration, recovery and signal-handler installation moved into `start()`, called from
  `applicationDidFinishLaunching` once a run loop exists.

> [!IMPORTANT]
> `attemptSilentRestore()` cannot succeed without root, so it will normally fail. That is
> expected and honest: at logout there is nobody to type a password. The consequence is
> that a logout or restart while Active leaves `SleepDisabled 1` in place until LidClosed
> is launched again. `SleepDisabled` is persisted to
> `/Library/Preferences/com.apple.PowerManagement.plist`, so it **survives reboots**.

Making logout cleanup actually work would require a LaunchDaemon. Not done; the first-run
warning and the README cover the exposure instead.

## 4. Concurrency

`PowerManager`, `StatusBarController` and `AppDelegate` are annotated `@MainActor`. The
signal-handler closure uses `MainActor.assumeIsolated`, which is valid because the
`DispatchSource` is created with `queue: .main`. Verified to compile against the package's
macOS 13 deployment target.

## 5. Testability

- **Three injection seams:** `CommandRunner` (process execution), `PrivilegedCommandRunner`
  (the authenticated path), and `UserNotifier` (modal alerts). The privileged path matters
  most — every critical bug lived there, and it was previously untestable because it called
  `NSAppleScript` directly.
- **22 tests** covering the `pmset` parser and the full transition table: activate success
  / cancel / failure / external-override, deactivate success / cancel / failure /
  unowned, silent restore success / failure / unowned, external-change syncing, and state
  file contents.
- **Tests are isolated from production state.** Each test gets a state file in a unique
  temporary directory, and `start()` is never called, so no signal handlers are installed
  and no recovery runs. An earlier version of the suite deleted the real
  `~/Library/Application Support/LidClosed/state.json` in `setUp`, which could strand a
  live override and leave the machine unable to sleep — running `swift test` must never be
  able to do that.

## 6. User-facing behaviour

- A one-time warning on first activation explains that the setting is global and persists
  across reboots, and how to revert it manually.
- Cancelling the password prompt on **enable** shows no alert: nothing changed and the menu
  already reads "Inactive". Cancelling on **disable** does alert, because sleep is still
  off and that is genuinely surprising.
- The menu distinguishes "Active — Managed by LidClosed" from "Active — Managed by system
  or another app".
- `README.md` documents the persistence, the uninstall order, and manual recovery.

## Known remaining items

- Debug builds carry SwiftPM's default `com.apple.security.get-task-allow` entitlement.
  Release builds do not.
- `CFBundleShortVersionString` / `CFBundleVersion` are hard-coded in `Resources/Info.plist`
  and not bumped by the install script.
- `runPrivilegedCommand` still interpolates its argument into AppleScript source. Only
  hard-coded literals are ever passed, and the call site is documented as such, but there
  is no quoting helper enforcing it.
