# TODO

Open items. Last reviewed 2026-08-09.

What has been fixed and why is in [WALKTHROUGH.md](WALKTHROUGH.md). Working conventions and
the design invariants are in [AGENTS.md](AGENTS.md).

---

## 1. Open

### 1.1 Logout while the Mac stays on

The boot daemon closed the large half of this problem: every way the Mac goes *down* —
restart, shutdown, kernel panic, power loss, a flat battery — is now cleaned up on the way
back up, before anyone logs in. What is left is the case where nothing reboots.

Logging out while lid-closed mode is Active terminates the app but not the daemon, which only
runs at boot. So `SleepDisabled 1` stays set at the login window until somebody logs in and
launches LidClosed, or runs `sudo pmset disablesleep 0`. On a laptop that means it will not
sleep while sitting at the login screen.

Two ways to close it, neither obviously worth it:

- **A persistent root service the app talks to.** The service notices the connection drop at
  logout and restores sleep. This is the textbook answer and it is genuinely complete — but it
  means a root process running continuously with the ability to change system power settings,
  which is a larger standing risk than the gap it removes. It also pulls in 2.1 below, since
  the connection needs a code-requirement check to be worth anything.
- **A timer.** `StartInterval` on the daemon, restoring sleep once the marker is present and
  no LidClosed is running. Simple, but it changes behaviour: a crash while lid-closed mode is
  on would re-enable sleep a few minutes later instead of at the next launch, which could
  interrupt exactly the overnight job the mode was switched on for.

The current position: leave it. The residual is bounded, visible in `./scripts/state.sh`, and
documented in the README.

---

## 2. Architectural decisions — out of scope by choice

These are not bugs. They are known limits of the current design, recorded so the reasoning
is not lost.

### 2.1 No privileged helper in the `SMAppService` sense

There *is* a root-owned helper script now, but it is invoked on demand with the user's own
admin authorization — not a persistent privileged service installed via `SMAppService` with a
code-requirement check. Root ownership of both the bundle and the helper is the mitigation for
the escalation path.

**Ad-hoc code signing is not a security boundary.** Verified experimentally: replacing the
executable with a different binary and re-signing ad-hoc (no certificate needed) yields
`valid on disk` and `satisfies its Designated Requirement` again, and the replacement runs.
Signing catches accidental corruption; `chown root:wheel` is what stops an attacker.

### 2.2 No notarization or signed release artifact

Users who download rather than build will hit a Gatekeeper warning. Requires a paid
Developer ID — a purchasing decision, not a code one.

---

## Done

Closed on 2026-08-09. Kept briefly because most of them carry a correction worth remembering.

- **Cleanup at restart and shutdown.** `scripts/lidclosed-helper.sh` plus the LaunchDaemon
  `com.akwnnwastaken.LidClosed.cleanup`, which runs the helper once at boot. The design note
  that matters: the marker the daemon reads lives in `/var/db` and is written **by root, in
  the same call that runs `pmset`** — the app's own `state.json` could not be used, because at
  boot no user home is guaranteed to be available. A one-shot `RunAtLoad` daemon was chosen
  over a persistent root process on purpose; see §1.1 for what that leaves open.
- **The `dist/` copy is no longer left behind.** `install.sh` deletes it after a successful
  install. The warning about it had been printed only in the branch where the user *declined*
  installation, so the one path that actually created the exposure said nothing.
- **Version numbers come from git.** `install.sh` stamps `CFBundleVersion` from the commit
  count, `CFBundleShortVersionString` from the latest tag when there is one, and records the
  short commit in a `LidClosedGitCommit` key. Prompted by a real incident: identifying the
  installed build meant comparing file timestamps against the git log, and the wrong
  conclusion was drawn twice. `./scripts/state.sh` now just prints it.
- **The debug entitlement is asserted against, not merely documented.** Release builds carry
  no entitlements and debug builds carry `com.apple.security.get-task-allow` (re-verified with
  `codesign -d --entitlements`). Since `install.sh` only ever packages `.build/release`, a
  debug binary could not reach the bundle anyway — so the item became a two-line check that
  refuses to continue if one ever does.
- **Single-instance enforcement.** `Sources/InstanceLock.swift`, an advisory `flock` taken
  before `PowerManager.start()`. A `flock` rather than a bundle-identifier check, because the
  case that actually caused trouble was the raw executable being run outside a bundle while
  developing. The kernel drops the lock on process death, so SIGKILL leaves nothing stale.
- **`caffeinate` option.** `Sources/AwakeKeeper.swift`, exposed as a checkmark menu item.
  An earlier note in this file claimed the kernel reaps the `caffeinate` child when the
  parent exits — **that was wrong.** Verified: an orphaned `caffeinate` keeps running and
  holds its assertions indefinitely. `-w <our pid>` is what makes it release them, and it
  was verified to work even when the parent is SIGKILLed.
- **Structural quoting for privileged commands.** `PrivilegedCommandRunner` takes an
  executable path plus an argument array instead of a command string, and quotes each
  argument for the shell and then for the AppleScript literal. The guarantee no longer
  depends on callers remembering to pass only literals. Covered by injection tests,
  including a round-trip through a real shell.
- **Keep Awake verification.** The `caffeinate` child is bound to the app's pid, disappears
  when switched off, and exits by itself after `pkill -9` on the app. A timed idle test in the
  same session appeared to show that lid-closed mode holds the display on too; that
  measurement was confounded, and the lock screen later established the opposite. See
  WALKTHROUGH.md §8 before trusting any idle test here.
