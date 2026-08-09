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

- **IOKit assertions removed entirely.** The assertion used here was
  `kIOPMAssertPreventUserIdleSystemSleep`, which `pmset disablesleep 1` already covers, and it
  did nothing for lid-close sleep — so it was redundant, and requiring both to agree was the
  direct cause of the worst bug (sleep left disabled with no recovery marker and no way to
  switch it off from the UI). The `caffeinate` option added in §7 also asserts display sleep,
  but a timed idle test later showed `pmset disablesleep` suppresses display sleep as well, so
  that option is a convenience rather than extra coverage — see §8.
- **Ownership separated from system state.** `isSleepDisabledSystemWide` reads
  `/usr/bin/pmset -g`; `isOwnedByUs` checks for our state file. The app only ever turns off
  an override it created.
- **External overrides are never claimed.** If sleep is already disabled by a manual
  `pmset` or another app, `activate()` runs no command and explains the situation. The menu
  reads "Managed Outside LidClosed…" and stays clickable, so the explanation is reachable
  rather than a dead end. (It was briefly greyed out, which made the explanation
  unreachable — a dead end with no guidance.)
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

- **Four injection seams:** `CommandRunner` (process execution), `PrivilegedCommandRunner`
  (the authenticated path), `BackgroundProcessLauncher` (long-lived children) and
  `UserNotifier` (modal alerts). The privileged path matters most — every critical bug lived
  there, and it was previously untestable because it called `NSAppleScript` directly.
- **Tests** covering the `pmset` parser and the full transition table: activate success
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

---

## 7. Second remediation round (2026-08-09)

Three items from TODO.md were closed. Each one came with a correction to something previously
believed or written down.

### Single-instance enforcement

`Sources/InstanceLock.swift` takes an advisory `flock` before `PowerManager.start()`. Without
it, a second instance read the first one's *live* state file, concluded the override was
stale, presented an unexplained authentication dialog and could silently re-enable sleep.

A `flock` rather than a bundle-identifier check, because the case that actually caused trouble
was the raw executable being run outside an app bundle while developing — where
`Bundle.main.bundleIdentifier` is nil. The kernel drops the lock on process death, so SIGKILL
leaves nothing stale behind. If the lock file cannot be opened at all the app continues
unlocked: a lost safeguard beats refusing to launch.

Verified end to end — the first instance acquires it, a second logs
`Another instance is already running` and exits, and no spurious recovery is triggered.

### The `caffeinate` option

`Sources/AwakeKeeper.swift`, exposed as a checkmark menu item, keeps the Mac awake while the
lid is open. It needs no password and writes no persistent state, so none of the ownership or
recovery machinery applies — the two lifecycles are deliberately kept separate.

**A correction:** the planning note in TODO.md had claimed the kernel reaps the `caffeinate`
child when the parent exits, so a crash would need no handling. That was wrong. An orphaned
`caffeinate` keeps running and holds its assertions indefinitely. The fix is
`caffeinate -dimsu -w <our pid>`: `-w` ties the assertions to our pid, and this was verified
to release them even when the parent is SIGKILLed.

Also worth recording: `-u` without `-t` expires after five seconds, so within `-dimsu` it acts
as a one-shot "turn the display on" while `-d` does the sustained work. That is intended.

### Structural quoting for privileged commands

`PrivilegedCommandRunner` now takes an executable path plus an argument array instead of a
command string, and quotes each argument for the shell and then for the enclosing AppleScript
literal. Previously the guarantee rested on callers remembering to pass only hard-coded
literals — documented, but not enforced.

Covered by injection tests, including a round trip through a real `/bin/sh` proving that
arguments carrying `;`, `$(…)`, backticks, backslashes and both quote styles arrive intact as
single arguments with nothing executed.

One of those tests initially failed, and the assertion was at fault rather than the escaping:
it searched for `" ;` in the output, which legitimately appears inside the correctly escaped
`\" ;`. The replacement strips escape sequences first and then asserts that only the two
delimiting quotes remain.

Test count went from 23 to 40.

---

## 8. The display question, settled on the third attempt (2026-08-09)

Whether lid-closed mode keeps the display on was claimed both ways before being measured
properly. The record matters more than the answer, because the wrong method looked convincing.

**What is true.** `pmset disablesleep 1` does **not** hold the display on; `caffeinate -dimsu`
does. The discriminator is the lock screen, and it takes seconds: lock with only lid-closed mode
active and the display turns off; lock with only Keep Awake active and it stays on. So the two
mechanisms are complementary, and both remain independently available.

**Why the earlier attempt was wrong.** An idle-timeout test was run instead: `SleepDisabled 1`,
`displaysleep 60`, Keep Awake off, machine untouched for 207 seconds. The display never turned
off, and that was taken as proof that `SleepDisabled` suppresses display sleep. It proved
nothing. The `pmset` log for the test window shows what was actually holding the display:

```
PID 43137(rcd)   UserIsActive "com.apple.rcdevent"                 00:54:31
PID 342(powerd)  UserIsActive "com.apple.powermanagement.lidopen"  00:11:45
```

`UserIsActive` assertions prevent display sleep and are held routinely, for tens of minutes at a
time. They do not appear under `PreventUserIdleDisplaySleep`, which read `0` throughout, and
`pmset -g` printed a plain `displaysleep 60` with no annotation. The pre-test assertion check
looked only at `PreventUserIdleDisplaySleep`, so it reported a clear field when the field was not
clear.

**Reverted as a result:** the greying-out of Keep Awake while lid-closed mode is on, which had
been justified entirely by that mismeasurement. Both switches are independent again, the status
line names both protections, and all six combinations get a distinct line.

**Recorded in AGENTS.md:** use the lock-screen test, never an idle test; and if the idle path
must be probed, sample `UserIsActive` and `InternalPreventDisplaySleep` too, not just
`PreventUserIdleDisplaySleep`.

The user found this by noticing that locking the screen behaved differently from leaving apps in
front — a difference no amount of reading `pmset` output would have surfaced.

## Known remaining items

Everything below is deliberate; see [TODO.md](TODO.md) for the reasoning.

- Debug builds carry SwiftPM's default `com.apple.security.get-task-allow` entitlement. Release
  builds do not.
- `CFBundleShortVersionString` / `CFBundleVersion` are hard-coded in `Resources/Info.plist` and
  not bumped by the install script.
- Logout and restart still leave lid-closed mode's override in place until the next launch;
  fixing that needs a LaunchDaemon. This is the only remaining functional gap. Keep Awake is
  unaffected, because `caffeinate -w` releases itself.
- No privileged helper and no notarization.
