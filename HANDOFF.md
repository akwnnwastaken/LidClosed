# HANDOFF

Snapshot of where the work stands, so a fresh session can pick up without re-deriving
context. **Updated 2026-08-09, at commit `56e5a5a`.** If the log has moved well past that,
treat this as history and trust the code.

Read [AGENTS.md](AGENTS.md) first — it holds the safety rules and the design invariants. This
file is only "what just happened, and what is next".

---

## Where things stand

Everything found across three rounds is either fixed or deliberately recorded. **Nothing is
queued.**

| Round | Outcome |
|-------|---------|
| First review (25 findings) | 22 fixed, 3 deferred |
| Second review (11 findings, after the first round) | 11 fixed |
| Manual test matrix (7 scenarios, real auth dialog) | 7/7 passed |
| Remaining-work round (single instance, caffeinate, quoting) | 3 closed |
| Keep Awake verification + display measurement | closed, one claim reverted |

Narrative of every change: [WALKTHROUGH.md](WALKTHROUGH.md). Everything still open, all of it
by choice: [TODO.md](TODO.md).

```
56e5a5a  Grey out Keep Awake while Lid Closed Mode is on
8aa9f8e  Revert the display-sleep claim: measured, pmset disablesleep covers it too
47fdb11  Add scripts/state.sh for inspecting live state
c5f6724  Report both protections in the status line
453eca3  Correct a wrong claim: the two mechanisms are complementary, not redundant
54f16f0  Close remaining TODO items: single instance, caffeinate option, quoting
7f117a2  Add AGENTS.md and HANDOFF.md
8e52fa6  Fix second-round review findings: test isolation, teardown, testability
```

Note `453eca3` followed by `8aa9f8e`: a claim was introduced and then reverted after being
measured. The reverted state is the correct one — see the warning below.

## Verification status

- `swift build` debug and release: clean, zero warnings.
- `swift test`: **47 tests** passing. Covers the `pmset -g` parser; the full transition table
  (activate success/cancel/failure/external-override, deactivate
  success/cancel/failure/unowned, silent restore success/failure/unowned, external-change
  syncing, state file contents); privileged-command quoting, including a round trip through a
  real `/bin/sh` with hostile arguments; the `caffeinate` keeper; the single-instance lock; and
  every reachable status line.
- Manual scenarios against the real authentication dialog: enable with password, enable
  cancelled, disable with password, disable cancelled (×4), `kill -9` then relaunch recovery,
  external `pmset` change, and external override not being claimed.
- Keep Awake verified through the real menu, including that its `caffeinate` child exits by
  itself after `pkill -9` on the app.
- Single-instance lock verified with two real instances: the second logs
  `Another instance is already running` and exits without triggering recovery.
- Established by measurement, because none of it could be assumed: AppleScript really returns
  **-128** on cancellation; hardened runtime does **not** break `do shell script`;
  `MainActor.assumeIsolated` back-deploys to macOS 13; `SleepDisabled` persists in
  `/Library/Preferences/com.apple.PowerManagement.plist` across reboots; an ad-hoc signature is
  **forgeable** without a certificate; an orphaned `caffeinate` child is **not** reaped when its
  parent dies, which is why `-w <pid>` is mandatory; and `pmset disablesleep` suppresses
  **display** sleep as well.

## First thing to do in a new session

Do not assume the machine is idle — the developer uses this app.

```bash
./scripts/state.sh
```

An active override owned by a running instance is a normal working state, not a leak. AGENTS.md
has the escape hatch if it is genuinely stuck.

---

## Next up

Nothing. Every remaining item in [TODO.md](TODO.md) is either a deliberate deferral (§1) or an
architectural decision already taken (§2). Do not start on those without asking.

If new work does come up, the highest-value unclaimed idea is a LaunchDaemon to make logout
cleanup actually work (TODO §2.1) — it is the only remaining *functional* gap, as opposed to a
stylistic one.

---

## Decisions already made — please do not re-litigate

A fresh reviewer tends to flag these as bugs. They are choices, with reasons.

- **Lid-closed mode covers strictly more than Keep Awake.** Measured with a timed idle test:
  `pmset disablesleep 1` suppresses display sleep too, invisibly — `pmset -g` keeps printing a
  plain `displaysleep 60` and `pmset -g assertions` reports `PreventUserIdleDisplaySleep 0`.
  Keep Awake's value is no password, no persistent setting, and self-release on crash — **not**
  extra coverage. A previous session inferred the opposite from those same `pmset` outputs and
  had to revert it; do not repeat that without running a timed idle test.
- **Keep Awake is greyed out and stopped while lid-closed mode is on.** It contributes nothing
  there. Greying without stopping would leave a checked item the user cannot uncheck.
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
  installed bundle is the mitigation. Do not "strengthen" the docs back toward saying signing
  prevents tampering.
- **No LaunchDaemon, no privileged helper, no notarization.** Deliberate scope limits, with the
  consequences written down in TODO.md §2.
- **`install.sh` does nothing when run non-interactively.** A safety property, not an oversight
  — it previously defaulted to running `sudo` in a pipe.
