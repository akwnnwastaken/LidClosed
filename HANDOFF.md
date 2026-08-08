# HANDOFF

Snapshot of where the work stands, so a fresh session can pick up without re-deriving
context. **Updated 2026-08-09.** This file describes a point in time — if the commit log has
moved well past the commits listed below, treat it as history and trust the code.

Read [AGENTS.md](AGENTS.md) first for the safety rules and design invariants. This file is
only "what just happened and what is next".

---

## Where things stand

Three rounds are complete and everything found in them is either fixed or recorded.

| Round | Outcome |
|-------|---------|
| First review (25 findings) | 22 fixed, 3 deliberately deferred |
| Second review (11 findings, after the first round's fixes) | 11 fixed |
| Manual test matrix (7 scenarios) | 7/7 passed |
| Remaining-work round (single instance, caffeinate, quoting) | 3 closed |

Full narrative of what changed and why: [WALKTHROUGH.md](WALKTHROUGH.md).
Everything still open: [TODO.md](TODO.md).

Relevant commits:

```
89656fb  Close remaining TODO items: single instance, caffeinate, quoting
7f117a2  Add AGENTS.md and HANDOFF.md
c2cfdfe  Clarify caffeinate item: user-selectable option for lid-open use
8e52fa6  Fix second-round review findings: test isolation, teardown, testability
9595a46  Fix UI state sync for external overrides (Scenario 6)
a8cc072  Apply Phase 1-3 fixes: state separation, root ownership, testing, UI caching
```

## Verification status

- `swift build` debug and release: clean, zero warnings.
- `swift test`: 40 tests passing. Covers the `pmset -g` parser, the full transition table
  (activate success/cancel/failure/external-override, deactivate
  success/cancel/failure/unowned, silent restore success/failure/unowned, external-change
  syncing, state file contents), privileged-command quoting including a round trip through a
  real shell, the `caffeinate` keeper, and the single-instance lock.
- Manual scenarios verified against the real authentication dialog: enable with password,
  enable cancelled, disable with password, disable cancelled (×4), `kill -9` followed by
  relaunch recovery, external `pmset` change, and external override not being claimed.
- Single-instance lock verified by running two real instances: the second logs
  `Another instance is already running` and exits without triggering recovery.
- Empirically established along the way, because none of it could be assumed: AppleScript
  really returns **-128** on cancellation; hardened runtime does **not** break
  `do shell script`; `MainActor.assumeIsolated` back-deploys to macOS 13; `SleepDisabled`
  persists in `/Library/Preferences/com.apple.PowerManagement.plist` across reboots; an
  ad-hoc signature is **forgeable** without a certificate; an orphaned `caffeinate` child is
  **not** reaped when its parent dies, which is why `-w <pid>` is mandatory.

## First thing to do in a new session

Do not assume the machine is idle. The developer uses this app.

```bash
/usr/bin/pmset -g | grep -i SleepDisabled
cat "$HOME/Library/Application Support/LidClosed/state.json"
pgrep -x LidClosed
```

An active override owned by a running instance is a normal working state, not a leak. See
AGENTS.md for the escape hatch if it is genuinely stuck.

---

## Next up

### 1. Manual-test the Keep Awake option — [TODO.md](TODO.md) §1.1

The only pending task. The `caffeinate` path has unit coverage but has not been exercised
through the real menu. The step that matters is the last one: enable it, `pkill -9 -x
LidClosed`, and confirm the `caffeinate` child exits by itself — that is the property which
keeps this mechanism free of recovery machinery, and it works only because of `-w`.

### 2. Nothing else is queued

Everything remaining in TODO.md is either a deliberate deferral (§2) or an architectural
decision already taken (§3). Do not start on those without asking.

## Decisions already made — please do not re-litigate

A fresh reviewer tends to flag these as bugs. They are choices, with reasons:

- **IOKit power assertions were removed on purpose.** They do not prevent lid-close sleep, so
  requiring both mechanisms to agree created a state where sleep was disabled with no way to
  turn it off. `pmset disablesleep` alone covers everything.
- **Cancelling Enable shows no alert; cancelling Disable does.** Cancelling an enable changes
  nothing and the menu already reads Inactive. Cancelling a disable leaves the Mac unable to
  sleep, which is surprising and must be reported. The asymmetry is intentional.
- **Recovery does not skip when the owning pid is still alive.** Pids are recycled, and
  wrongly skipping recovery is the worse failure.
- **Ad-hoc signing is kept, but is not claimed as a security control.** Root ownership of the
  installed bundle is the mitigation. Do not "strengthen" the docs back toward saying signing
  prevents tampering.
- **No LaunchDaemon, no privileged helper, no notarization.** All three are deliberate scope
  limits with the consequences written down in TODO.md §3. The logout gap is real and known:
  logging out while lid-closed mode is Active leaves sleep disabled until the next launch.
- **The two mechanisms are kept separate on purpose.** `PowerManager` has ownership tracking
  and recovery because it mutates a persistent system setting; `AwakeKeeper` has neither
  because `caffeinate -w` cleans itself up. Generalising one over the other would add
  machinery to a path that does not need it.
- **`caffeinate` keeps `-dimsu` including `-u`.** Its five-second expiry is understood: it
  acts as a one-shot display wake, and `-d` does the sustained work.
- **`install.sh` does nothing when run non-interactively.** That is a safety property, not an
  oversight — it previously defaulted to running `sudo` in a pipe.
