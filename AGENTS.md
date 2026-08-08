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

---

## ⚠️ Read this before running anything

This app changes a **global, persistent system setting**. `SleepDisabled` is written to
`/Library/Preferences/com.apple.PowerManagement.plist` under `SystemPowerSettings`, so it
**survives reboots**. A mistake here does not produce a failed test — it produces a Mac that
never sleeps.

**Check the state before and after any work that touches `PowerManager` or the install
script:**

```bash
./scripts/state.sh    # app, lid-closed mode, keep awake, state file, display timer
```

It distinguishes an override owned by LidClosed from one set outside it, and ignores
`caffeinate` processes belonging to other tools (it matches on `-dimsu`, which is ours).
The raw equivalents, if you need them individually:

```bash
/usr/bin/pmset -g | grep -i SleepDisabled                       # 0 = normal, 1 = disabled
cat "$HOME/Library/Application Support/LidClosed/state.json"     # our ownership marker
pgrep -x LidClosed                                               # is an instance running
```

**Escape hatch, if sleep is stuck off:**

```bash
sudo pmset disablesleep 0
rm -f "$HOME/Library/Application Support/LidClosed/state.json"
```

Never delete `state.json` while `SleepDisabled` is `1` and no instance is running — that
marker is the only thing that lets the next launch recover.

---

## Commands

```bash
swift build -c debug          # or -c release
swift test                    # 47 tests, no privileged calls, no real state file touched
./scripts/install.sh          # build + bundle + ad-hoc sign + install to /Applications
./scripts/state.sh            # read-only: what the app is actually doing right now
```

`install.sh` requires `sudo` for the `/Applications` step and **skips installation entirely
when stdin is not a TTY**, so piping it does nothing. Run it from a real terminal.

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
10. **Keep Awake is unavailable while lid-closed mode is on.** `refreshState()` stops the
    `caffeinate` child and `updateUI()` greys the item with an explanatory title, because
    lid-closed mode already covers it. Disabled rather than hidden, and stopped rather than
    left checked — a greyed item the user cannot uncheck is the dead end this repo already
    fixed once on the other toggle. Consequence: only four UI states are reachable, and
    `statusText` has a distinct line for each.
11. **Only one instance may run.** `InstanceLock` is acquired before `PowerManager.start()`.
    Without it, a second instance reads the first one's live state file, concludes the
    override is stale, and tries to undo it.

---

## Traps discovered the hard way

- **`open dist/LidClosed.app` is unreliable for testing.** Launch Services resolves by
  bundle ID and may activate the copy in `/Applications` instead. Always launch the exact
  binary by full path when you care which build runs.
- **`NSLog` output is not retrievable with `log show`.** Multiple predicates
  (`process ==`, `processImagePath CONTAINS`, `eventMessage CONTAINS`, with `--info
  --debug`) all return nothing. To see logs, run the binary directly in a terminal:
  `/Applications/LidClosed.app/Contents/MacOS/LidClosed`.
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
- **`pmset disablesleep 1` suppresses display sleep too, and `pmset -g` does not show it.**
  Measured: `SleepDisabled 1`, `displaysleep 60`, no assertion held, machine idle for 207
  seconds — the display never turned off. Throughout, `pmset -g` kept printing a plain
  `displaysleep 60` with no "prevented by" annotation and `pmset -g assertions` reported
  `PreventUserIdleDisplaySleep 0`. Reading those outputs and concluding the display would
  still sleep is a mistake this repo has already made once; only a timed idle test settles it.
  Consequence: lid-closed mode covers strictly more than Keep Awake, so the two are redundant
  when both on — not complementary.
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
  reason. Do not reintroduce them as a way to avoid the password prompt; see TODO §2.1 for
  the `caffeinate` option, which is the legitimate lid-open use case.

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
