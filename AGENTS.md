# AGENTS.md

Working notes for AI agents (and humans) contributing to LidClosed.

LidClosed is a macOS menu bar utility (`LSUIElement`) offering two independent ways to stop
the Mac sleeping: **Lid Closed Mode**, which runs `pmset disablesleep 1` through an
administrator authentication prompt and covers clamshell operation, and **Keep Awake**, which
holds IOKit assertions through a `caffeinate` child and only works with the lid open. SwiftPM
package, Swift tools 5.9, deployment target macOS 13.

Nearly all of the complexity in this repo belongs to the first mechanism, because it mutates
a persistent system setting and therefore needs ownership tracking and crash recovery. The
second has none of that by design.

Lid Closed Mode reaches `pmset` through a **root-owned helper script** installed outside the
bundle, and a **LaunchDaemon** runs that helper once at every boot to undo an override a
previous session never restored. The app falls back to calling `pmset` directly when the
helper is absent, so a hand-built copy still works — with cleanup at restart being what it
loses.

---

## ⚠️ Read this before running anything

This app changes a **global, persistent system setting**. `SleepDisabled` is written to
`/Library/Preferences/com.apple.PowerManagement.plist` under `SystemPowerSettings`, so it
**survives reboots**. A mistake here does not produce a failed test — it produces a Mac that
never sleeps.

**Check the state before and after any work that touches `PowerManager` or the install
script:**

```bash
./scripts/state.sh    # app, both switches, state file, display timer,
                      # installed build, helper, boot daemon, boot marker
```

It distinguishes an override owned by LidClosed from one set outside it, and ignores
`caffeinate` processes belonging to other tools (it matches on `-dimsu`, which is ours).
The raw equivalents, if you need them individually:

```bash
/usr/bin/pmset -g | grep -i SleepDisabled                       # 0 = normal, 1 = disabled
cat "$HOME/Library/Application Support/LidClosed/state.json"     # our ownership marker
pgrep -x LidClosed                                               # is an instance running
ls -l /var/db/com.akwnnwastaken.LidClosed.active                 # the boot daemon's marker
```

There are now **two** ownership markers, and they answer different questions.
`state.json` lives in the user's home and is what the app reads. The `/var/db` marker is
root-owned and is what the boot daemon reads, because at boot no user home is guaranteed to
be available. The helper writes and clears them in the same privileged call that flips
`pmset`, so they normally agree; when they disagree the system self-heals, since a boot
cleanup on an already-sleeping system is a no-op that just clears the marker.

**Escape hatch, if sleep is stuck off:**

```bash
sudo pmset disablesleep 0
rm -f "$HOME/Library/Application Support/LidClosed/state.json"
sudo rm -f /var/db/com.akwnnwastaken.LidClosed.active
```

Never delete `state.json` while `SleepDisabled` is `1` and no instance is running — that
marker is the only thing that lets the next launch recover.

---

## Commands

```bash
swift build -c debug          # or -c release
swift test                    # 53 tests, no privileged calls, no real state file touched
./scripts/install.sh          # build + bundle + sign + install app, helper and daemon
./scripts/uninstall.sh        # removes all of it, restoring sleep first
./scripts/state.sh            # read-only: what the app is actually doing right now
```

`install.sh` and `uninstall.sh` require `sudo` and **do nothing when stdin is not a TTY**, so
piping either one is a no-op. Run them from a real terminal.

`install.sh` runs `launchctl bootstrap` on the daemon, which executes the cleanup immediately.
That is safe because the helper's `cleanup` refuses to act while a LidClosed process is alive
— otherwise re-installing while lid-closed mode was on would restore sleep out from under the
user, with the app still believing it owned the override.

---

## Architecture

| File | Role |
|------|------|
| `Sources/LidClosedApp.swift` | `@main` entry point |
| `Sources/AppDelegate.swift` | Lifecycle; calls `PowerManager.shared.start()` |
| `Sources/StatusBarController.swift` | Menu bar UI, `NSMenuDelegate`, cached system state |
| `Sources/PowerManager.swift` | The state machine — activation, recovery, signal handling |
| `Sources/AwakeKeeper.swift` | The `caffeinate` option — independent of `PowerManager` |
| `Sources/InstanceLock.swift` | `flock` guaranteeing a single running instance |
| `Sources/CommandRunner.swift` | Seam: plain process execution |
| `Sources/PrivilegedCommandRunner.swift` | Seam: the `with administrator privileges` path |
| `Sources/BackgroundProcessLauncher.swift` | Seam: long-lived child processes |
| `Sources/UserNotifier.swift` | Seam: modal alerts |
| `scripts/lidclosed-helper.sh` | Root-owned helper: `enable` / `disable` / `cleanup` |
| `Resources/com.akwnnwastaken.LidClosed.cleanup.plist` | The boot-time LaunchDaemon |
| `scripts/uninstall.sh` | Removes app, helper, daemon, markers — sleep restored first |

Installed layout for the two out-of-bundle pieces:

| Path | Owner / mode |
|------|--------------|
| `/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper` | `root:wheel` 755 |
| `/Library/LaunchDaemons/com.akwnnwastaken.LidClosed.cleanup.plist` | `root:wheel` 644 |
| `/var/db/com.akwnnwastaken.LidClosed.active` | `root:wheel` 600, written by the helper |

The seams exist so the state machine is testable without triggering a real authentication
dialog, spawning a real child process, or opening a modal window. Anything new that touches
the system or shows UI should go through a seam too, or it becomes untestable.

---

## Design invariants — do not break these

Each of these was a real bug once. See [WALKTHROUGH.md](WALKTHROUGH.md) for the history.

1. **System state and ownership are two different questions.** `isSleepDisabledSystemWide`
   reads `pmset -g`; `isOwnedByUs` checks for `state.json`. Never collapse them into one
   boolean.
2. **Never disable an override we did not create.** If sleep is already off and we do not
   own it, explain and change nothing.
3. **On failure, keep `state.json`.** A cancelled or failed restore must preserve the marker
   so the next launch can recover. Deleting it on failure is the original worst bug.
4. **`PowerManager.init` is pure.** Migration, recovery and signal-handler installation live
   in `start()`, called from `applicationDidFinishLaunching`. Recovery can show a modal
   dialog and needs a run loop; constructing an object must not install process-wide signal
   handlers.
5. **Interactive and silent teardown are separate.** `deactivate()` authenticates (menu
   Disable, Quit). `attemptSilentRestore()` never shows a dialog (signal handlers,
   `applicationWillTerminate`). Do not merge them — merging caused a double password prompt,
   and a dialog at logout just gets the process killed.
6. **Owning-pid liveness is diagnostic only.** `recoverStaleState()` logs whether the pid is
   alive but never uses it to skip recovery, because pids are recycled and wrongly skipping
   recovery leaves the Mac unable to sleep. The second-instance problem this would otherwise
   create is solved by invariant 10 instead — by preventing a second instance, not by
   trusting liveness.
7. **Tests must never touch the real state file.** `stateFileURL` is injectable; every test
   uses a temp directory and never calls `start()`. An earlier suite deleted the production
   `state.json` in `setUp` and could strand a live override.
8. **The privileged API takes an executable plus an argument array, never a command
   string.** `AppleScriptPrivilegedRunner` quotes each argument for the shell and then for
   the AppleScript literal. Do not add a convenience overload that accepts a whole command
   line — that would put the burden back on callers to remember, which is how it used to be.
9. **The two keep-awake mechanisms have separate lifecycles.** `PowerManager` owns the
   `pmset` override, with a state file and recovery. `AwakeKeeper` owns the `caffeinate`
   child, with neither, because there is nothing to recover. Do not generalise the ownership
   logic over both.
10. **The status line must describe both switches, and both stay independently available.**
    Neither mechanism covers the other, so reporting one hides real information.
    `statusText` is pure and gives all six combinations a distinct string. Keep Awake was
    briefly greyed out while lid-closed mode was on, on the strength of a mismeasurement; do
    not do that again without the lock-screen check above.
11. **Only one instance may run.** `InstanceLock` is acquired before `PowerManager.start()`.
    Without it, a second instance reads the first one's live state file, concludes the
    override is stale, and tries to undo it.
12. **The helper's root ownership is a security boundary, not hygiene.** The app runs the
    helper through `with administrator privileges`, so a copy the logged-in user could modify
    would hand root to any process running as that user — the same escalation that
    root-owning the bundle closed. It lives directly under `/Library` (`root:wheel`, not
    group-writable) and deliberately **not** under `/Library/Application Support`, which is
    `root:admin`. Never relax the mode, and never move it somewhere user-writable.
13. **The direct-`pmset` fallback must stay.** `overrideCommand(enable:)` uses the helper only
    when it exists and is executable, and otherwise calls `pmset` exactly as the app did
    before the daemon existed. Removing the fallback breaks every hand-built copy and every
    install predating the helper. `helperPath` is injectable for the same reason
    `stateFileURL` is: without it, assertions about the privileged command would depend on
    whether the machine running the suite happens to have the helper installed.
14. **Boot cleanup never acts while an instance is alive.** The helper's `cleanup` checks
    `pgrep -x LidClosed` before touching anything. At boot that check is free; it exists for
    `launchctl bootstrap` during a re-install.

---

## Traps discovered the hard way

- **`open dist/LidClosed.app` is unreliable for testing.** Launch Services resolves by
  bundle ID and may activate the copy in `/Applications` instead. Always launch the exact
  binary by full path when you care which build runs.
- **`log` is a zsh builtin. Always write `/usr/bin/log`.** Plain `log show …` fails with
  `too many arguments`, and with `2>/dev/null` it silently prints nothing at all — which
  looks exactly like "there are no matching log entries". This wasted time twice, once here
  and once when it made an earlier trap note overstate its case.
- **`NSLog` output is not retrievable with `log show`; `logger` output is.** Re-checked with
  `/usr/bin/log` to rule out the builtin above: a `[LidClosed]` line from a binary run in a
  terminal reaches stderr and never appears in the unified log, under either
  `process == "LidClosed"` or a free-text search. To read the app's own logs, run the binary
  directly:

  ```bash
  /Applications/LidClosed.app/Contents/MacOS/LidClosed
  ```

  This is exactly why the helper uses `logger` instead of writing to stdout — the boot
  cleanup has no terminal, so a message that only reached stderr would be lost:

  ```bash
  /usr/bin/log show --last 1h --style compact --predicate 'process == "logger"' | grep -i cleanup
  ```
- **There is no `timeout(1)` on macOS.** Use a background process plus `kill`, or install
  coreutils for `gtimeout`.
- **A second instance is now refused by `InstanceLock`**, and logs
  `Another instance is already running`. If you are wondering why a freshly built binary
  exits immediately, check whether the installed app is running.
- **An orphaned `caffeinate` child is not reaped.** Verified: when its parent dies, a plain
  `caffeinate` keeps running and holds its assertions indefinitely. This is why
  `AwakeKeeper` launches it as `caffeinate -dimsu -w <our pid>` — `-w` makes it release and
  exit when our pid goes away, which was verified to survive a SIGKILL of the parent. Never
  drop `-w`.
- **`caffeinate -u` without `-t` expires after five seconds.** In `-dimsu` it therefore acts
  as a one-shot "turn the display on"; `-d` does the sustained work. Intended, not a bug.
- **`pmset disablesleep 1` does not hold the display on. Keep Awake does. Settle it by
  locking the screen, never by an idle test.** Locking with only lid-closed mode active turns
  the display off; locking with only Keep Awake active leaves it on. That is the reliable
  discriminator, and it takes seconds.

  An idle-timeout test is **not** reliable here, and this repo got it wrong twice before
  finding out why. `UserIsActive` assertions routinely hold the display on for tens of
  minutes — during one 207-second idle test, `rcd` held `UserIsActive "com.apple.rcdevent"`
  for 54 minutes and `powerd` held `UserIsActive "com.apple.powermanagement.lidopen"`. None of
  them appear under `PreventUserIdleDisplaySleep`, which read `0` the whole time, and
  `pmset -g` printed a plain `displaysleep 60`. The display stayed on for reasons that had
  nothing to do with `SleepDisabled`, and the result was mistaken for evidence.

  If you must probe the idle path, sample `pmset -g assertions` throughout and look for
  `UserIsActive` and `InternalPreventDisplaySleep` as well — not just
  `PreventUserIdleDisplaySleep`.
- **Ad-hoc code signing is not a security boundary.** Anyone can replace the binary and
  re-sign ad-hoc without a certificate; verification then passes again. `chown root:wheel`
  on the installed bundle is the actual mitigation. Do not describe signing as preventing
  tampering.
- **`codesign --deep` is deprecated for signing.** Use `--options runtime`. Verified that
  hardened runtime does *not* break `NSAppleScript`'s `do shell script`.
- **`MainActor.assumeIsolated` is required** inside `DispatchSource` event handlers created
  with `queue: .main`. Verified to compile and run against the macOS 13 deployment target.
- **The IDE's SourceKit diagnostics go stale** after adding files or changing signatures.
  Trust `swift build`, not the inline squiggles.
- **IOKit power assertions do not prevent lid-close sleep.** They were removed for this
  reason. Do not reintroduce them as a way to avoid the password prompt — `AwakeKeeper`'s
  `caffeinate` option is the legitimate lid-open use case.

---

## Conventions

- Docs, comments and commit messages in English, even though issues are often discussed in
  Turkish.
- Comments explain **why**, not what. The invariants above are the kind of thing that
  belongs in a comment at the site that depends on them.
- `@MainActor` on anything touching AppKit, `NSAppleScript`, or `PowerManager` state.
- Prefer adding a test over manual verification. The manual test matrix in
  [HANDOFF.md](HANDOFF.md) exists only for what genuinely cannot be automated: the real
  authentication dialog.
