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

**Status: analysed, deliberately not started. Deferred 2026-08-09, to be revisited.** No
decision has been taken between the options below — the analysis is recorded here so it does
not have to be redone.

#### What happens, step by step

1. `loginwindow` sends the app SIGTERM.
2. The signal handler runs `attemptSilentRestore()`, which calls `pmset disablesleep 0` as the
   user and **fails** — it needs root, and there is nobody to authenticate.
3. `state.json` is kept on purpose, for next-launch recovery.
4. The `/var/db` marker is kept too: removing it also needs root.
5. The app exits.
6. **The daemon never gets a turn.** LaunchDaemons are system-wide and are not unloaded at
   logout; ours ran at boot and exited, and nothing triggers it again.

So `SleepDisabled 1` stays set at the login window until somebody logs in and launches
LidClosed, runs `sudo pmset disablesleep 0`, or restarts. On a laptop off mains power that is
battery drain while the machine sits at the login screen.

#### Why it is structurally awkward

Undoing `pmset disablesleep` needs root, and at logout nobody can authenticate. The fix
therefore has to be something that *already holds root and is still alive at logout*. Daemons
qualify — but launchd offers a daemon no "user logged out" trigger, because daemons are
deliberately independent of sessions. The daemon has to notice the app's absence by itself.

#### Options

**A — persistent root service plus XPC.** `KeepAlive` daemon holding a Mach service; the app
connects and declares ownership, and the connection dropping at logout fires the restore.
Textbook, and genuinely complete: logout, crash, force-quit, immediately.

The cost is not the code. It is a root process running continuously that can change system
power settings, and — once it accepts instructions — must verify the caller's code signature
via its audit token. A meaningful check needs a stable designated requirement, which means a
paid Developer ID: against an ad-hoc signature the requirement is forgeable and the check is
theatre. Skip the check and *any* local process can ask a root service to change power
settings, which is strictly worse than today. So A drags in §2.1 and §2.2 as prerequisites.
Not a bigger patch — a different project.

**B — a plain timer.** `StartInterval` on the existing daemon: if the marker is present and no
LidClosed is running, restore sleep. No IPC, no persistent process, no signing problem.

Rejected as it stands, because it cannot tell "logged out" from "crashed while I was using
it". Today a crash with lid-closed mode on leaves the Mac awake until the next launch, which
asks. Under B sleep returns a few minutes later — potentially killing the overnight job the
mode was switched on for.

**C — B, gated on nobody being logged in.** The refinement that removes B's objection: act
only when the console has no user. `stat -f%Su /dev/console` reports the logged-in user's name
during a session (measured: `ahmed`), and is expected to report `root` at the login window. The
condition becomes *marker present **and** console user is `root`*.

- Logout → cleaned up within the poll interval.
- Crash during a session → untouched, current behaviour preserved.
- No new attack surface: no IPC, no persistent process, no code-requirement chain.

Cost: a root one-shot waking every N minutes indefinitely, and a dependency on `/dev/console`
ownership as the logged-out signal.

> [!IMPORTANT]
> **The `root` half of that signal is unmeasured** — confirming it requires actually logging
> out. If it is wrong, C does not work. Verify it before writing any code.

**D — a `LoginWindow`-session LaunchAgent.** `LimitLoadToSessionType: LoginWindow` starts an
agent as the login window comes up, which is the right *trigger* for once. Whether such an
agent runs with enough privilege to change power settings on current macOS is **not known** —
this was not researched. Do not propose it as a solution until it is.

#### How bad the gap actually is

| | |
|---|---|
| Needs | mode on, log out, **not** restart/shutdown, and not log back in |
| Effect | no sleep at the login window; battery drain if unplugged |
| Visible | yes — `./scripts/state.sh` |
| Self-limiting | any restart or shutdown fixes it; so does logging in and launching the app |
| Frequency | on a single-user Mac, logging out usually means shutting down — rare |

Real, but narrow, and not silent.

#### Recommendation on file

**C**, if it is closed at all: roughly fifteen lines in the helper plus one plist key, keeping
crash behaviour intact and adding no standing privilege. First step is a measurement, not code
— check `stat -f%Su /dev/console` at the login window.

**A is not recommended**: it depends on a paid Developer ID and, done carelessly, leaves
security worse than it is now. **B alone is not recommended**; C is its corrected form.

Leaving it open is also a defensible answer, which is why this section exists rather than a
patch.

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
