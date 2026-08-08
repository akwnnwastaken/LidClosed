# TODO

Open items left after the code-review remediation of 2026-08-08.

What was already fixed is documented in [WALKTHROUGH.md](WALKTHROUGH.md). The manual test
matrix (7 scenarios covering the real authentication dialog, crash recovery and external
overrides) was completed on 2026-08-08 — all 7 passed, so nothing is pending there.

---

## 1. Real gaps — worth fixing

### 1.1 Single-instance enforcement

**Status:** open · **Severity:** medium · **Found:** 2026-08-08, during manual testing

If two LidClosed instances run at once, the second one treats the first one's *live*
override as stale, presents an admin authentication dialog and — if authorized — undoes it.
Observed in the logs:

```
[LidClosed] Found state file from pid 83260 (still running), 63s old
[LidClosed] Stale override detected — re-enabling system sleep
```

The first instance then still believes it owns the override until its next
`syncStateWithSystem()` call, at which point the UI self-heals to Inactive. Not
catastrophic, but it produces an unexplained password prompt and silently re-enables sleep.

**Why it is not fixed by a liveness check:** `recoverStaleState()` in
`Sources/PowerManager.swift` deliberately logs whether the owning pid is still alive but
never uses it to skip recovery, because pids are recycled and wrongly skipping recovery
would leave the Mac unable to sleep. That trade-off is correct and should stay.

**Fix instead by preventing the second instance:**
- add `LSMultipleInstancesProhibited` to `Resources/Info.plist`, and/or
- at launch, check `NSRunningApplication.runningApplications(withBundleIdentifier:)` and
  exit early if another instance is already running.

Note that running the raw binary (`.build/release/LidClosed` or
`dist/LidClosed.app/Contents/MacOS/LidClosed`) alongside the installed app is the easiest
way to reproduce this, and is a normal thing to do while developing.

---

## 2. Planned

### 2.1 Add a `caffeinate -dimsu` mode

**Status:** planned

Add a second, lighter mode backed by `caffeinate` instead of `pmset disablesleep`.

Flags (from `man caffeinate`):

| Flag | Effect |
|------|--------|
| `-d` | prevent display sleep |
| `-i` | prevent system idle sleep |
| `-m` | prevent disk idle sleep |
| `-s` | prevent system sleep — **only valid on AC power** |
| `-u` | declare user active; turns the display on if off |

Two things to get right:

- **`-u` without `-t` defaults to a 5 second timeout**, so in `-dimsu` the `-u` assertion
  drops almost immediately. Either pair it with `-t`, or leave `-u` out — the other four
  flags are what actually hold the machine awake.
- **`caffeinate` creates IOKit power assertions, which do not prevent lid-close sleep.**
  This is the same reason IOKit assertions were removed from `PowerManager` (see
  [WALKTHROUGH.md](WALKTHROUGH.md) §2). So this is a *complement* to lid-closed mode, not a
  replacement for it — it covers "keep the Mac awake with the lid open".

Why it is worth adding anyway: the assertions are held by a child process and are released
the moment that process exits. That means **no admin password, no root, no persistent
system setting, and no crash-recovery problem at all** — the entire class of bugs this
project spent a review cycle fixing simply does not exist on this path. A good default for
users who do not actually need clamshell operation.

Implementation sketch: spawn `caffeinate` as a child `Process`, retain the handle, and
`terminate()` it on deactivate/quit. `caffeinate -w <our pid>` is an alternative that ties
the assertion's lifetime to the app's pid instead.

---

## 3. Deliberately deferred — low value, known

### 3.1 Debug builds carry `com.apple.security.get-task-allow`

SwiftPM adds this entitlement to debug builds by default; release builds have none
(verified with `codesign -d --entitlements`). It permits attaching a debugger to a process
that performs privileged operations. Only matters if a debug binary is ever distributed.

### 3.2 Version numbers are hard-coded

`CFBundleShortVersionString` (1.0.0) and `CFBundleVersion` (1) live in
`Resources/Info.plist` and are never bumped by `scripts/install.sh`, so version drift is
guaranteed. Worth solving if releases ever become a thing.

### 3.3 No quoting helper for the privileged command

`AppleScriptPrivilegedRunner.run(command:)` in `Sources/PrivilegedCommandRunner.swift`
interpolates its argument into AppleScript source. Only hard-coded literals are ever
passed, and the call site documents that requirement, but nothing *enforces* it. A single
future caller passing a file path or user input would get arbitrary command execution as
root. A quoting/escaping helper — or an argument-array API instead of a command string —
would make the guarantee structural rather than conventional.

---

## 4. Architectural decisions — out of scope by choice

These are not bugs. They are known limits of the current design, recorded so the reasoning
is not lost.

### 4.1 No cleanup at logout or shutdown

Restoring sleep requires an admin password, and at logout there is nobody to type one, so
`attemptSilentRestore()` fails by design. Consequence: logging out or restarting while
LidClosed is Active leaves `SleepDisabled 1` in place until LidClosed is launched again.

This matters because `SleepDisabled` is persisted to
`/Library/Preferences/com.apple.PowerManagement.plist` under `SystemPowerSettings`, so it
**survives reboots** (verified). Making logout cleanup actually work would require a
LaunchDaemon. Mitigated instead by the first-run warning and the README.

### 4.2 No privileged helper

The app authenticates through AppleScript's `with administrator privileges` rather than
installing a privileged helper via `SMAppService` with a code-requirement check. Root
ownership of the installed bundle is the mitigation for the escalation path.

**Ad-hoc code signing is not a security boundary.** Verified experimentally: replacing the
executable with a different binary and re-signing ad-hoc (no certificate needed) yields
`valid on disk` and `satisfies its Designated Requirement` again, and the replacement runs.
Signing catches accidental corruption; `chown root:wheel` is what stops an attacker.

### 4.3 No notarization or signed release artifact

Users who download rather than build will hit a Gatekeeper warning. Requires a paid
Developer ID.

### 4.4 The `dist/` copy is user-owned

`scripts/install.sh` hardens only what it installs into `/Applications`. The bundle left in
`dist/` is owned by the building user and is perfectly launchable, so running that copy
reopens the privilege-escalation path. The script prints a warning about this, and about
installing by hand with `cp -R` instead of the script.
