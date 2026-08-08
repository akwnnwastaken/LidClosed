# LidClosed

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="LidClosed Icon">
</p>

<p align="center">
  <strong>Keep your Mac awake with the lid closed.</strong>
</p>

<p align="center">
  A lightweight macOS menu bar utility that prevents your Mac from sleeping when you close the lid.<br>
  No bloat. No extra features. Just one job, done right.
</p>

---

## What it does

LidClosed sits in your menu bar and lets you toggle **lid-closed mode** with a single click. When active, your Mac will continue running even when you close the lid — perfect for:

- 🎵 Playing music through external speakers with the lid closed
- 📺 Using an external monitor in clamshell mode without a charger
- ⬇️ Keeping downloads running overnight
- 🖥️ Running servers or long tasks while the Mac is tucked away

## How it works

LidClosed uses `pmset disablesleep 1` to disable system sleep entirely, including lid-close sleep (requires admin password on activation). 

Disabling the mode, or quitting from the menu, prompts for your password again and restores normal sleep behavior.

### Safety Features

- **State Tracking** — The app writes a state file to `~/Library/Application Support/LidClosed` when it activates the override, and only ever disables an override it knows it owns. If sleep was already disabled by something else, LidClosed leaves it alone.
- **Crash Recovery** — If the app crashes or is force-killed, the next launch detects the stale state file and offers to re-enable sleep. If a restore fails or you cancel the prompt, the state file is kept so recovery can be retried.
- **Security** — The installation script installs the bundle with root ownership (`root:wheel`), so a process running as your user cannot swap the executable and inherit the root privileges the app requests. The bundle is also ad-hoc signed, which makes accidental corruption detectable — note that ad-hoc signatures are not a defence against a determined local attacker, since anyone can re-sign without a certificate.

> [!NOTE]
> Logout and restart cannot be cleaned up automatically: restoring sleep needs an admin password, and there is nobody to type one at logout. If you log out while LidClosed is Active, sleep stays disabled until you launch LidClosed again — or run `sudo pmset disablesleep 0` yourself.

## Installation

### Quick Install (Build + Install to /Applications)

```bash
git clone https://github.com/akwnnwastaken/LidClosed.git
cd LidClosed
./scripts/install.sh
```

This builds the app, creates a signed `.app` bundle with an icon, and securely installs it to `/Applications` (requires `sudo`). After installation, you can find it with **Spotlight** (Cmd+Space → "LidClosed").

### Manual Build

```bash
git clone https://github.com/akwnnwastaken/LidClosed.git
cd LidClosed
swift build -c release
```

The binary will be at `.build/release/LidClosed`.

## Usage

1. Launch **LidClosed** — it appears as a laptop icon in your menu bar
2. Click the icon → **▶ Enable Lid Closed Mode**
3. Enter your admin password when prompted
4. Close your lid — your Mac stays awake! ☕
5. Click the icon → **⏹ Disable Lid Closed Mode** to return to normal behavior

### Menu Bar States

| State | Icon | Description |
|-------|------|-------------|
| Inactive | 🔒💻 | Normal sleep behavior |
| Active | 🔓💻 | Mac won't sleep when lid is closed |

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+
- Admin privileges (for `pmset` commands)

## Troubleshooting & Uninstallation

> [!WARNING]
> LidClosed modifies a **global system setting**. If you delete the app while it is Active, your Mac will never sleep again until you manually revert the setting.

**Always click "Disable Lid Closed Mode" before uninstalling the app.**

If you forgot, or if the app crashes and you don't want to launch it again, open Terminal and run:

```bash
sudo pmset disablesleep 0
```

To fully uninstall:
1. Ensure sleep is re-enabled (see above).
2. `sudo rm -rf /Applications/LidClosed.app`
3. `rm -rf ~/Library/Application Support/LidClosed`

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ☕ to keep your Mac awake.
</p>
