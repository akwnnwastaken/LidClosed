# HANDOFF

Snapshot of where the work stands, so a fresh session can pick up without re-deriving
context. **Written 2026-08-08.** This file describes a point in time — if the commit log has
moved well past `c2cfdfe`, treat it as history and trust the code.

Read [AGENTS.md](AGENTS.md) first for the safety rules and design invariants. This file is
only "what just happened and what is next".

---

## Where things stand

Two review rounds are complete and everything found in them is either fixed or recorded.

| Round | Outcome |
|-------|---------|
| First review (25 findings) | 22 fixed, 3 deliberately deferred |
| Second review (11 findings, after the first round's fixes) | 11 fixed |
| Manual test matrix (7 scenarios) | 7/7 passed |

Full narrative of what changed and why: [WALKTHROUGH.md](WALKTHROUGH.md).
Everything still open: [TODO.md](TODO.md).

Relevant commits:

```
c2cfdfe  Clarify caffeinate item: user-selectable option for lid-open use
8e52fa6  Fix second-round review findings: test isolation, teardown, testability
9595a46  Fix UI state sync for external overrides (Scenario 6)
a8cc072  Apply Phase 1-3 fixes: state separation, root ownership, testing, UI caching
```

## Verification status

- `swift build` debug and release: clean, zero warnings.
- `swift test`: 23 tests passing. Covers the `pmset -g` parser and the full transition table
  (activate success/cancel/failure/external-override, deactivate
  success/cancel/failure/unowned, silent restore success/failure/unowned, external-change
  syncing, state file contents).
- Manual scenarios verified against the real authentication dialog: enable with password,
  enable cancelled, disable with password, disable cancelled (×4), `kill -9` followed by
  relaunch recovery, external `pmset` change, and external override not being claimed.
- Empirically established along the way, because none of it could be assumed: AppleScript
  really returns **-128** on cancellation; hardened runtime does **not** break
  `do shell script`; `MainActor.assumeIsolated` back-deploys to macOS 13; `SleepDisabled`
  persists in `/Library/Preferences/com.apple.PowerManagement.plist` across reboots; an
  ad-hoc signature is **forgeable** without a certificate.

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

### 1. Single-instance enforcement — [TODO.md](TODO.md) §1.1

The only known real gap. A second instance treats the first's live override as stale, pops an
unexplained password prompt, and can undo it. Fix by preventing the second instance
(`LSMultipleInstancesProhibited`, or an `NSRunningApplication` check at launch) — **not** by
making recovery trust pid liveness, which is a deliberate decision explained in AGENTS.md
invariant 6.

### 2. `caffeinate` option — [TODO.md](TODO.md) §2.1

Requested by the repo owner as **an option for when the lid is not closed**: a way to keep
the Mac awake without the admin password, alongside lid-closed mode rather than replacing it.
`caffeinate` uses IOKit assertions, which do not cover clamshell — so it cannot replace
`pmset disablesleep`, and that limit is the whole reason it is a separate option.

The TODO entry lists the flag semantics (including that `-u` without `-t` silently expires
after 5 seconds) and four design questions to settle before writing code. The most important
one: this path needs **no state file and no recovery**, so keep its lifecycle separate rather
than generalising the existing ownership logic over both mechanisms.

---

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
  limits with the consequences written down in TODO.md §4. The logout gap is real and known:
  logging out while Active leaves sleep disabled until the next launch.
- **`install.sh` does nothing when run non-interactively.** That is a safety property, not an
  oversight — it previously defaulted to running `sudo` in a pipe.
