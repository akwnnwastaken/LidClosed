# LidClosed

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
2. **`pmset disablesleep`** — Disables system sleep entirely (requires admin password on activation)

When you quit the app or disable the mode, sleep behavior is fully restored.

## Installation

### Build from source

```bash
git clone https://github.com/yourusername/LidClosed.git
cd LidClosed
swift build -c release
```

The binary will be at `.build/release/LidClosed`.

### Run

```bash
.build/release/LidClosed
```

Or copy it to your Applications folder:

```bash
cp .build/release/LidClosed /usr/local/bin/lidclosed
```

## Usage

1. Launch LidClosed — it appears as a laptop icon in your menu bar
2. Click the icon → **Enable Lid Closed Mode**
3. Enter your admin password when prompted (required for `pmset`)
4. Close your lid — your Mac stays awake! ☕
5. Click the icon → **Disable Lid Closed Mode** to return to normal

### Menu Bar Icons

| State | Icon | Meaning |
|-------|------|---------|
| Inactive | 🔒💻 | Normal sleep behavior |
| Active | 🔓💻 | Lid closed mode — Mac won't sleep |

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+
- Admin privileges (for `pmset` commands)

## Safety

- Sleep is **always re-enabled** when you quit the app
- The app registers for termination notifications to ensure cleanup
- If the app crashes, run `sudo pmset disablesleep 0` to manually re-enable sleep

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ☕ to keep your Mac awake.
</p>
