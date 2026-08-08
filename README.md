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

LidClosed uses two mechanisms to reliably prevent sleep:

1. **IOKit Power Assertions** — Creates a system-level assertion that prevents idle sleep
2. **`pmset disablesleep`** — Disables system sleep entirely, including lid-close sleep (requires admin password on activation)

When you quit the app or disable the mode, sleep behavior is fully restored.

### Safety Features

- **Crash recovery** — If the app crashes, the next launch automatically detects and re-enables sleep
- **Signal handlers** — SIGTERM/SIGINT/SIGHUP are caught to ensure cleanup on forced termination
- **State verification** — If the user cancels the password prompt, the partial activation is rolled back

## Installation

### Quick Install (Build + Install to /Applications)

```bash
git clone https://github.com/akwnnwastaken/LidClosed.git
cd LidClosed
./scripts/install.sh
```

This builds the app, creates a `.app` bundle with an icon, and installs it to `/Applications`. After installation, you can find it with **Spotlight** (Cmd+Space → "LidClosed").

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

## Troubleshooting

If the app crashes or is force-killed and your Mac no longer sleeps:

```bash
sudo pmset disablesleep 0
```

This manually re-enables sleep. The app also does this automatically on the next launch.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ☕ to keep your Mac awake.
</p>
