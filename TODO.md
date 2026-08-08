# TODO

Open items. Last reviewed 2026-08-09.

What has been fixed and why is in [WALKTHROUGH.md](WALKTHROUGH.md). Working conventions and
the design invariants are in [AGENTS.md](AGENTS.md).

---

## 1. Deliberately deferred — low value, known

### 1.1 Debug builds carry `com.apple.security.get-task-allow`

SwiftPM adds this entitlement to debug builds by default; release builds have none
(verified with `codesign -d --entitlements`). It permits attaching a debugger to a process
that performs privileged operations. Only matters if a debug binary is ever distributed.

### 1.2 Version numbers are hard-coded

`CFBundleShortVersionString` (1.0.0) and `CFBundleVersion` (1) live in
`Resources/Info.plist` and are never bumped by `scripts/install.sh`. Not worth automating
until there is an actual release process to hang it off.

---

## 2. Architectural decisions — out of scope by choice

These are not bugs. They are known limits of the current design, recorded so the reasoning
is not lost.

### 2.1 No cleanup at logout or shutdown

Restoring sleep requires an admin password, and at logout there is nobody to type one, so
`attemptSilentRestore()` fails by design. Consequence: logging out or restarting while
lid-closed mode is Active leaves `SleepDisabled 1` in place until LidClosed is launched
again.

This matters because `SleepDisabled` is persisted to
`/Library/Preferences/com.apple.PowerManagement.plist` under `SystemPowerSettings`, so it
**survives reboots** (verified). Making logout cleanup actually work would require a
LaunchDaemon. Mitigated instead by the first-run warning and the README.

Note that the Keep Awake option has no such problem — `caffeinate -w` releases its
assertions when the app dies, whatever the cause.

### 2.2 No privileged helper

The app authenticates through AppleScript's `with administrator privileges` rather than
installing a privileged helper via `SMAppService` with a code-requirement check. Root
ownership of the installed bundle is the mitigation for the escalation path.

**Ad-hoc code signing is not a security boundary.** Verified experimentally: replacing the
executable with a different binary and re-signing ad-hoc (no certificate needed) yields
`valid on disk` and `satisfies its Designated Requirement` again, and the replacement runs.
Signing catches accidental corruption; `chown root:wheel` is what stops an attacker.

### 2.3 No notarization or signed release artifact

Users who download rather than build will hit a Gatekeeper warning. Requires a paid
Developer ID.

### 2.4 The `dist/` copy is user-owned

`scripts/install.sh` hardens only what it installs into `/Applications`. The bundle left in
`dist/` is owned by the building user and is perfectly launchable, so running that copy
reopens the privilege-escalation path. The script prints a warning about this, and about
installing by hand with `cp -R` instead of the script.

---

## Done

Keep Awake was manually verified on 2026-08-09: the `caffeinate` child appears bound to the
app's pid, disappears when switched off, and — the point of the exercise — exits by itself
after `pkill -9` on the app. A timed idle test in the same session also disproved the claim
that lid-closed mode leaves the display sleeping; see WALKTHROUGH.md §8.

Closed on 2026-08-09, kept here briefly because each one carries a correction worth
remembering.

- **Single-instance enforcement.** `Sources/InstanceLock.swift`, an advisory `flock` taken
  before `PowerManager.start()`. A `flock` rather than a bundle-identifier check, because the
  case that actually caused trouble was the raw executable being run outside a bundle while
  developing. The kernel drops the lock on process death, so SIGKILL leaves nothing stale.
- **`caffeinate` option.** `Sources/AwakeKeeper.swift`, exposed as a checkmark menu item.
  The earlier note in this file claimed the kernel reaps the `caffeinate` child when the
  parent exits — **that was wrong.** Verified: an orphaned `caffeinate` keeps running and
  holds its assertions indefinitely. `-w <our pid>` is what makes it release them, and it
  was verified to work even when the parent is SIGKILLed.
- **Structural quoting for privileged commands.** `PrivilegedCommandRunner` now takes an
  executable path plus an argument array instead of a command string, and quotes each
  argument for the shell and then for the AppleScript literal. The guarantee no longer
  depends on callers remembering to pass only literals. Covered by injection tests,
  including a round-trip through a real shell.
