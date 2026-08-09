# HANDOFF

Snapshot of where the work stands, so a fresh session can pick up without re-deriving
context. **Updated 2026-08-09, on top of commit `fae9171`.** If the log has moved well past
that, treat this as history and trust the code.

Read [AGENTS.md](AGENTS.md) first — it holds the safety rules and the design invariants. This
file is only "what just happened, and what is next".

---

## Where things stand

Everything found across the review rounds is fixed, and the items that had been parked as
deliberate deferrals are now closed too. **One functional gap is left, by choice** — see
"Next up".

| Round | Outcome |
|-------|---------|
| First review (25 findings) | 22 fixed, 3 deferred |
| Second review (11 findings, after the first round) | 11 fixed |
| Manual test matrix (7 scenarios, real auth dialog) | 7/7 passed |
| Remaining-work round (single instance, caffeinate, quoting) | 3 closed |
| Keep Awake verification | passed |
| Display question (three attempts) | settled by the lock-screen test |
| README audit against the code | 5 corrections, no code changes |
| Deferred-items round (boot daemon, dist/, versioning, entitlement) | 4 closed |

Narrative of every change: [WALKTHROUGH.md](WALKTHROUGH.md) — the most recent round is §9.
Everything still open, all of it by choice: [TODO.md](TODO.md).

```
fae9171  Purge the last traces of the reverted display claim
8ecba91  Correct the README against the code
8d6d78e  Restore the complementary display behaviour, settled by the lock screen
5479a2c  Reconcile the deferred-item count in HANDOFF
0473858  Bring the handoff docs in line with the finished state
56e5a5a  Grey out Keep Awake while Lid Closed Mode is on
8aa9f8e  Revert the display-sleep claim: measured, pmset disablesleep covers it too
47fdb11  Add scripts/state.sh for inspecting live state
c5f6724  Report both protections in the status line
453eca3  Correct a wrong claim: the two mechanisms are complementary, not redundant
54f16f0  Close remaining TODO items: single instance, caffeinate option, quoting
```

Read the display-related commits as a sequence, not individually: `453eca3` claimed the two
mechanisms are complementary, `8aa9f8e` and `56e5a5a` reversed that on the strength of a
mismeasured idle test, and `8d6d78e` restores it after the lock-screen test settled the
question. **`453eca3`'s conclusion is the correct one.** WALKTHROUGH.md §8 has the full account.

## What changed most recently

Lid Closed Mode no longer calls `pmset` directly when the full installation is present. It goes
through a **root-owned helper** (`/Library/PrivilegedHelperTools/…`), and a **LaunchDaemon**
runs that helper once at every boot to undo an override a previous session never restored.
That closes the app's last functional defect: a restart used to leave the Mac unable to sleep
until LidClosed was launched again.

Three things about it that are easy to get wrong:

- **The helper's `root:wheel` ownership is a security boundary.** The app invokes it through an
  admin prompt, so a user-writable helper would hand root to any process running as the user.
  It lives under `/Library` because that is `root:wheel` and not group-writable, unlike
  `/Library/Application Support`.
- **The `pmset` fallback is deliberate.** No helper installed — a hand-built copy, a `cp -R`
  install — and the app behaves exactly as it did before the daemon existed.
- **There are two markers now.** `state.json` in the user's home is what the app reads;
  `/var/db/com.akwnnwastaken.LidClosed.active` is what the daemon reads, because at boot no
  user home is guaranteed to be available.

`./scripts/uninstall.sh` is new and is now the documented way to remove things: it restores
sleep first, while the helper still exists.

## Verification status

- `swift build` debug and release: clean, zero warnings.
- `swift test`: **53 tests** passing. Covers the `pmset -g` parser; the full transition table
  (activate success/cancel/failure/external-override, deactivate
  success/cancel/failure/unowned, silent restore success/failure/unowned, external-change
  syncing, state file contents); helper routing and all three fallback cases; privileged-command
  quoting, including a round trip through a real `/bin/sh` with hostile arguments; the
  `caffeinate` keeper; the single-instance lock; and every reachable status line.
- Manual scenarios against the real authentication dialog: enable with password, enable
  cancelled, disable with password, disable cancelled (×4), `kill -9` then relaunch recovery,
  external `pmset` change, and external override not being claimed.
- Keep Awake verified through the real menu, including that its `caffeinate` child exits by
  itself after `pkill -9` on the app.
- Single-instance lock verified with two real instances: the second logs
  `Another instance is already running` and exits without triggering recovery.
- Helper verified without root, as far as that goes: the usage path, and `cleanup` while the app
  was running — it exited 0, left `SleepDisabled 1` untouched, and logged
  `cleanup: LidClosed is running, leaving the override alone`.
- Established by measurement, because none of it could be assumed: AppleScript really returns
  **-128** on cancellation; hardened runtime does **not** break `do shell script`;
  `MainActor.assumeIsolated` back-deploys to macOS 13; `SleepDisabled` persists in
  `/Library/Preferences/com.apple.PowerManagement.plist` across reboots; an ad-hoc signature is
  **forgeable** without a certificate; an orphaned `caffeinate` child is **not** reaped when its
  parent dies, which is why `-w <pid>` is mandatory; and `pmset disablesleep` does **not** hold
  the **display** on — established with the lock screen, after an idle test said otherwise.

### Not yet verified on real hardware

The boot cleanup has **not** been observed doing its job at an actual boot. Doing so needs a
privileged install and a restart:

```bash
./scripts/install.sh                     # installs helper + daemon, needs sudo
# switch Lid Closed Mode on, then reboot without switching it off
./scripts/state.sh                       # expect: lid closed off, boot marker none
/usr/bin/log show --last 30m --style compact --predicate 'process == "logger"' | grep -i cleanup
```

Note `/usr/bin/log`, not `log` — see the zsh trap in AGENTS.md.

## First thing to do in a new session

Do not assume the machine is idle — the developer uses this app.

```bash
./scripts/state.sh
```

An active override owned by a running instance is a normal working state, not a leak. It now
also reports which build is installed, and whether the helper, daemon and boot marker are in
place. AGENTS.md has the escape hatch if something is genuinely stuck.

---

## Next up

One item, deliberately not started: **logout while the Mac stays on** still leaves the override
in place, because nothing reboots and the daemon only runs at boot. TODO.md §1.1 has the two
candidate designs and why neither is obviously worth it. Do not start on it without asking.

---

## Decisions already made — please do not re-litigate

A fresh reviewer tends to flag these as bugs. They are choices, with reasons.

- **The boot daemon is a one-shot, not a persistent service.** `RunAtLoad` with no `KeepAlive`
  covers every route by which the Mac goes down, because the setting is still there on the way
  back up. A root process running continuously with the ability to change power settings is a
  larger standing risk than the residual it would remove.
- **The helper writes a second marker instead of reusing `state.json`.** At boot there is no
  guaranteed user home to read. Not redundancy.
- **`cleanup` refuses to act while a LidClosed process is alive.** This is not defensive
  padding: `launchctl bootstrap` during a re-install runs it immediately, and without the guard
  it would restore sleep under a running app that still believed it owned the override.
- **The two mechanisms are complementary and both stay available.** `pmset disablesleep` does
  not hold the display on; `caffeinate` does. Settled by locking the screen — with only
  lid-closed mode active the display turns off, with only Keep Awake active it stays on.
  **Do not use an idle-timeout test to re-check this.** Two earlier sessions got opposite wrong
  answers, the second because `UserIsActive` assertions (`rcd`, `powerd`'s `lidopen`) had held
  the display on for tens of minutes and do not show up under `PreventUserIdleDisplaySleep`.
  See WALKTHROUGH.md §8 and the trap in AGENTS.md.
- **Keep Awake was briefly greyed out while lid-closed mode was on, and that was reverted.** It
  rested on the mismeasurement above. Do not reintroduce it without the lock-screen check.
- **The IOKit assertion inside `PowerManager` was removed on purpose.** It asserted only
  `PreventUserIdleSystemSleep`, which `pmset disablesleep` already covers, and did nothing for
  lid-close sleep — so requiring both to agree created a state where sleep was disabled with no
  way to turn it off.
- **Cancelling Enable shows no alert; cancelling Disable does.** Cancelling an enable changes
  nothing and the menu already reads Inactive. Cancelling a disable leaves the Mac unable to
  sleep, which is surprising and must be reported.
- **Recovery does not skip when the owning pid is still alive.** Pids are recycled, and wrongly
  skipping recovery is the worse failure. The second-instance problem that would otherwise
  create is solved by `InstanceLock` instead.
- **The two mechanisms keep separate lifecycles.** `PowerManager` has ownership tracking and
  recovery because it mutates a persistent system setting; `AwakeKeeper` has neither because
  `caffeinate -w` cleans itself up.
- **`caffeinate` keeps `-dimsu` including `-u`.** Its five-second expiry is understood: it acts
  as a one-shot display wake, and `-d` does the sustained work.
- **Ad-hoc signing is kept, but is not claimed as a security control.** Root ownership of the
  installed bundle and the helper is the mitigation. Do not "strengthen" the docs back toward
  saying signing prevents tampering.
- **No `SMAppService` helper, no notarization.** Deliberate scope limits, with the consequences
  written down in TODO.md §2.
- **`install.sh` and `uninstall.sh` do nothing when run non-interactively.** A safety property,
  not an oversight — `install.sh` previously defaulted to running `sudo` in a pipe.
