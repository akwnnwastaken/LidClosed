# LidClosed

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="LidClosed Icon">
</p>

<p align="center">
  <strong>Keep your Mac awake with the lid closed.</strong>
</p>

<p align="center">
  A lightweight macOS menu bar utility that prevents your Mac from sleeping — with the lid closed, or just with it open.<br>
  Two switches, no bloat.
</p>

---

## What it does

LidClosed sits in your menu bar and offers two independent ways to stop your Mac from sleeping.

### 🔓 Lid Closed Mode

Your Mac keeps running **even when you close the lid** — perfect for:

- 🎵 Playing music through external speakers with the lid closed
- 📺 Using an external monitor in clamshell mode without a charger
- ⬇️ Keeping downloads running overnight
- 🖥️ Running servers or long tasks while the Mac is tucked away

### ☕ Keep Awake (Lid Open)

Keeps the display and system awake **as long as the lid stays open**. Nothing more — close the lid and the Mac sleeps normally.

Reach for this one when you do not actually need clamshell operation: it needs **no admin password**, changes **no system settings**, and stops the moment you switch it off or quit the app.

## How it works

| | Lid Closed Mode | Keep Awake |
|---|---|---|
| Mechanism | `pmset disablesleep 1` | `caffeinate -dimsu -w <pid>` |
| Keeps the system awake | ✅ | ✅ |
| Works with the lid closed | ✅ | ❌ |
| Keeps the **display** on | ❌ | ✅ |
| Admin password | required | not needed |
| Changes a system setting | yes, and it persists across reboots | no |
| If the app crashes | recovered at next boot, or next launch | released automatically |

Disabling lid-closed mode, or quitting from the menu, prompts for your password again and restores normal sleep behavior. Keep Awake just stops.

Neither one covers the other, so running both is a real combination: **the Mac stays up with the lid closed *and* the screen stays on.** The difference is easiest to see by locking the screen — with only Lid Closed Mode on, the display turns off; with only Keep Awake on, it stays on.

Keep Awake is the better choice whenever the lid can stay open: it needs no admin password, touches no persistent system setting, and leaves nothing to clean up if the app dies. Use Lid Closed Mode when the lid has to close — and turn on both if you also want the screen to stay on.

### Safety Features

- **State Tracking** — The app writes a state file to `~/Library/Application Support/LidClosed` when it activates the override, and only ever disables an override it knows it owns. If sleep was already disabled by something else, LidClosed leaves it alone.
- **Crash Recovery** — If the app crashes or is force-killed, the next launch detects the stale state file and offers to re-enable sleep. If a restore fails or you cancel the prompt, the state file is kept so recovery can be retried.
- **Cleanup at Boot** — `scripts/install.sh` also installs a small root-owned helper and a LaunchDaemon that runs once at every boot. If a previous session left sleep disabled, the daemon restores it before you log in. This covers every way the Mac can go down — restart, shutdown, kernel panic, power loss, a flat battery — and is what stops the setting from outliving the session that asked for it. It only ever undoes an override LidClosed marked as its own, and does nothing while LidClosed is running.
- **Single Instance** — Only one copy runs at a time. A second instance would see the first one's state file, mistake the live override for a leftover, and try to undo it.
- **Security** — The installation script installs the bundle with root ownership (`root:wheel`), so a process running as your user cannot swap the executable and inherit the root privileges the app requests. The bundle is also ad-hoc signed, which makes accidental corruption detectable — note that ad-hoc signatures are not a defence against a determined local attacker, since anyone can re-sign without a certificate.

> [!NOTE]
> This applies to **Lid Closed Mode only**. Restoring sleep needs root, and at logout there is nobody to type a password, so the app itself cannot clean up on the way out — the boot daemon above is what does it instead, on the way back in.
>
> One gap is left: **logging out while the Mac stays on.** Nothing reboots, so the daemon does not get its turn, and sleep stays disabled at the login window until someone logs in and launches LidClosed — or runs `sudo pmset disablesleep 0`. Closing that too would mean a root service running continuously, which is a bigger trade than the gap deserves. **Keep Awake has no such problem** and releases itself whatever happens to the app.

## Installation

### Quick Install (Build + Install to /Applications)

```bash
git clone https://github.com/akwnnwastaken/LidClosed.git
cd LidClosed
./scripts/install.sh
```

This builds the app, creates a signed `.app` bundle with an icon, and securely installs it to `/Applications` (requires `sudo`). After installation, you can find it with **Spotlight** (Cmd+Space → "LidClosed").

It also installs two small pieces outside the app, both owned by `root`:

| Path | What it is |
|---|---|
| `/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper` | Runs `pmset` and records whether LidClosed owns the override |
| `/Library/LaunchDaemons/com.akwnnwastaken.LidClosed.cleanup.plist` | Runs the helper once at boot to restore sleep if a session left it disabled |

The build copy in `dist/` is deleted once the hardened copy is in place — it is owned by your user and launching it would reopen the escalation path that root ownership closes. Remove everything later with `./scripts/uninstall.sh`.

### Manual Build

```bash
git clone https://github.com/akwnnwastaken/LidClosed.git
cd LidClosed
swift build -c release
```

The binary will be at `.build/release/LidClosed`.

### Tests

```bash
swift test
```

The suite covers the `pmset` output parser, the activate/deactivate/recovery state machine, privileged-command quoting, the `caffeinate` keeper and the single-instance lock. It runs entirely against injected test doubles: no test performs a privileged operation, spawns `caffeinate`, or touches the real state file in `~/Library/Application Support/LidClosed`.

## Usage

**Lid closed:**

1. Launch **LidClosed** — it appears as a laptop icon in your menu bar
2. Click the icon → **▶ Enable Lid Closed Mode**
3. Enter your admin password when prompted
4. Close your lid — your Mac stays awake! ☕
5. Click the icon → **⏹ Disable Lid Closed Mode** to return to normal behavior

**Lid open** — no password, nothing to undo:

1. Click the icon → **Keep Awake (Lid Open)**
2. A checkmark appears and the icon becomes a cup
3. Click it again to switch it off

### Menu Bar States

| Icon | Status line |
|------|-------------|
| 🔒💻 | ○ Inactive — normal sleep behavior |
| ☕ | ◐ Awake — but sleeps if you close the lid |
| 🔓💻 | ● Awake with the lid closed — display can still turn off |
| 🔓💻 | ● Awake with the lid closed — display stays on too |
| 🔓💻 | ● Sleep disabled outside LidClosed — display can still turn off |
| 🔓💻 | ● Sleep disabled outside LidClosed — display stays on |

The status line names both protections, because neither implies the other. The icon reflects Lid Closed Mode when it is on, since that is the one that survives closing the lid.

The menu bar draws template SF Symbols — `lock.laptopcomputer`, `cup.and.saucer` and `lock.open.laptopcomputer` — so they follow your light/dark menu bar. The emoji above are approximations.

If sleep was disabled by something other than LidClosed — a manual `pmset` command or another app — the toggle reads **⚠ Managed Outside LidClosed…** and clicking it explains how to hand control over instead of changing the setting. LidClosed only ever turns off an override it created.

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+
- Admin privileges — for Lid Closed Mode only; Keep Awake needs none

## Troubleshooting & Uninstallation

> [!WARNING]
> LidClosed modifies a **global system setting**. Deleting the app by hand while it is Active leaves your Mac unable to sleep. If the boot daemon is still installed, the next restart repairs it; if you delete that too, nothing will, and you have to revert the setting yourself.

**Always click "Disable Lid Closed Mode" before uninstalling, and uninstall with `./scripts/uninstall.sh`** rather than dragging the app to the Trash. (Keep Awake needs no such care — it leaves nothing behind.)

To check what is currently set, run `./scripts/state.sh` from the repository.

If you forgot, or if the app crashes and you don't want to launch it again, open Terminal and run:

```bash
sudo pmset disablesleep 0
```

To fully uninstall:

```bash
./scripts/uninstall.sh
```

It restores sleep first — while the helper is still installed — and only then removes the app, the helper, the boot daemon and the per-user state. Doing it by hand in the other order leaves a Mac that never sleeps and nothing installed to fix it.

If sleep is disabled but LidClosed's marker is absent, the script says so and leaves the setting alone: something else disabled it, and it is not LidClosed's to undo.

Removing things by hand instead:

```bash
sudo pmset disablesleep 0
sudo launchctl bootout system/com.akwnnwastaken.LidClosed.cleanup
sudo rm -f /Library/LaunchDaemons/com.akwnnwastaken.LidClosed.cleanup.plist
sudo rm -f /Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper
sudo rm -f /var/db/com.akwnnwastaken.LidClosed.active
sudo rm -rf /Applications/LidClosed.app
rm -rf ~/Library/Application\ Support/LidClosed
```

## Development

Contributor notes live next to the code:

- [AGENTS.md](AGENTS.md) — safety rules, architecture map, design invariants, and traps found the hard way. Worth reading before touching `Sources/PowerManager.swift` or `scripts/install.sh`.
- [TODO.md](TODO.md) — what is deliberately not done, and why.
- [WALKTHROUGH.md](WALKTHROUGH.md) — how the current design was arrived at, including measurements that overturned earlier assumptions.
- [HANDOFF.md](HANDOFF.md) — snapshot of the current state.

To see what the app is doing at any moment:

```bash
./scripts/state.sh
```

It is read-only, and reports the running instance, both switches, the state file, the display timer, which build is installed (version, build number and commit, stamped by `install.sh` from git), and whether the helper, boot daemon and boot marker are in place.

`./scripts/uninstall.sh` removes everything, in an order that cannot strand a disabled-sleep setting.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ☕ to keep your Mac awake.
</p>
