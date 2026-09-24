# PinWindow

[![Download](https://img.shields.io/github/v/release/justwy/PinWindow?label=Download&style=for-the-badge)](https://github.com/justwy/PinWindow/releases/latest/download/PinWindow-1.0.dmg)
[![GitHub Release](https://img.shields.io/github/v/release/justwy/PinWindow?style=flat-square)](https://github.com/justwy/PinWindow/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-orange?style=flat-square&logo=buy-me-a-coffee)](https://buymeacoffee.com/justwyo)

Keep any macOS window always on top — a free, open-source alternative to Rectangle Pro's pinning feature.

> **[Download PinWindow-1.0.dmg](https://github.com/justwy/PinWindow/releases/latest/download/PinWindow-1.0.dmg)** (100 KB) — signed and notarized, no Gatekeeper warnings.

### Install via Homebrew

```bash
brew tap justwy/pinwindow
brew install --cask pinwindow
```

## How It Works

There's no public macOS API to change another app's window level. PinWindow works around this by creating a **live pixel-perfect mirror** of the target window using ScreenCaptureKit, displayed in a floating overlay panel that passes all mouse events through to the real window underneath.

```
┌─────────────────────────────────────┐
│     Floating Mirror (our panel)     │  level = .floating
│     SCStream capture @ 60fps        │  ignoresMouseEvents = true
│     AXObserver tracks position      │  collectionBehavior: allSpaces
├─────────────────────────────────────┤
│     Real Window (behind others)     │  receives all input via passthrough
└─────────────────────────────────────┘
```

When you click on the pinned window, a global click monitor detects the click and activates the real app, bringing its window to the front for interaction. The mirror then hides itself, since the real window now has focus, and shows again once focus moves elsewhere.

## Features

- **Menu bar app** with dynamic app list — click any running app to pin it
- **Per-window pin/unpin** — pin multiple windows from the same app independently
- **Global hotkeys** — Option+P to pin frontmost, Option+U to unpin last
- **Click-to-activate** — clicking a pinned window brings the real app to focus
- **Hides while focused** — the mirror hides itself while the real window has focus, so there is no lag while you interact with it, and shows again once focus moves elsewhere
- **Auto-unpin** — mirrors are automatically removed when the source app quits
- **Window title display** — pinned Chrome tabs show their page title so you can tell them apart
- **HUD notifications** — brief overlay confirms pin/unpin actions
- **Works across Spaces** — pinned windows follow you to all desktops

## Requirements

- **macOS 13 (Ventura)** or later
- **Screen Recording** permission — System Settings > Privacy & Security > Screen Recording
- **Accessibility** permission — System Settings > Privacy & Security > Accessibility

## Install

### From DMG

Download `PinWindow-1.0.dmg` from [Releases](https://github.com/justwy/PinWindow/releases), open it, and drag PinWindow to Applications. The DMG is signed with Developer ID and notarized by Apple — no Gatekeeper warnings.

### From Source

```bash
git clone https://github.com/justwy/PinWindow.git
cd PinWindow
./build.sh
```

## Usage

### Menu Bar

Launch PinWindow — a 📌 icon appears in the menu bar. Click it to see:

- **PINNED** — currently pinned windows (click to unpin)
- **PIN AN APP** — all running apps with visible windows (click to pin)

The icon shows 📌 when idle and 📌 2 (with count) when windows are pinned.

### Hotkeys

| Shortcut | Action |
|---|---|
| Option+P | Pin the frontmost window |
| Option+U | Unpin the last pinned window |

### CLI

```bash
# Run as menu bar app
open PinWindow.app

# Pin/unpin from command line
./build.sh pin Safari
./build.sh pin Chrome
./build.sh unpin Safari
./build.sh unpin           # unpin all

# List windows
./build.sh list
./build.sh list Chrome
```

## Building & Distribution

### Development build

```bash
./build.sh                 # compile, ad-hoc sign, launch
```

### Signed & notarized DMG

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_PROFILE="your-notary-profile" \
./package.sh
```

This compiles, signs with hardened runtime, creates a DMG with an Applications symlink, signs the DMG, submits to Apple's notarization service, and staples the ticket.

### Setting up notarization (one-time)

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) > Sign-In and Security > App-Specific Passwords

2. Store credentials in your keychain:
   ```bash
   xcrun notarytool store-credentials "your-notary-profile" \
       --apple-id YOUR_EMAIL \
       --team-id YOUR_TEAM_ID \
       --password xxxx-xxxx-xxxx-xxxx
   ```

3. If `codesign` fails with `errSecInternalComponent`, run:
   ```bash
   security set-key-partition-list -S apple-tool:,apple:,codesign: \
       -s -k "YOUR_MAC_PASSWORD" ~/Library/Keychains/login.keychain-db
   ```

## Architecture

The entire app is a single Swift file (`pin.swift`, ~800 lines):

| Component | Role |
|---|---|
| `CaptureManager` | Wraps `SCStream` for 60fps window capture, filtering to complete frames only |
| `MirrorPanel` | `NSPanel` overlay that displays the capture, syncs position via `AXObserver`, detects clicks to activate the real window, hides while the real window has focus |
| `PinManager` | Singleton managing all mirrors — pin/unpin by name, PID, or window ID |
| `AppDelegate` | Menu bar UI with dynamic `NSMenuDelegate`, CLI argument handling, permission requests |
| Hotkey handler | Carbon `RegisterEventHotKey` for global Option+P/U |

### APIs Used

| API | Purpose | Status |
|---|---|---|
| **ScreenCaptureKit** | Window capture at 60fps | Public, stable |
| **Accessibility** (`AXObserver`) | Window move/resize tracking | Public, stable since 10.2 |
| **`_AXUIElementGetWindow`** | Map AXUIElement to CGWindowID | Private, stable since 10.5 |
| **AVFoundation** | Render captured frames | Public, stable |
| **Carbon** (`RegisterEventHotKey`) | Global hotkeys | Deprecated but functional |
| **AppKit** (`NSPanel`) | Floating overlay window | Public, stable |

### Why not just change the window level?

`CGSSetWindowLevel` (the private API Rectangle Pro uses) only works on windows your own process owns. On modern macOS, calling it on another app's window returns success but silently does nothing. The ScreenCaptureKit mirror approach is the only reliable method that works on macOS 13+.

## Compatibility

| macOS | Support |
|---|---|
| 15+ (Sequoia/Tahoe) | Full — uses new `sampleBufferRenderer` API |
| 14 (Sonoma) | Full — uses `pointPixelScale` for Retina sizing |
| 13 (Ventura) | Full — falls back to `frame.width * 2` |
| < 13 | Not supported |

## Known Limitations

- **Fully obscured windows** — if the real window is completely hidden behind others, macOS may throttle its rendering. The mirror shows the last captured frame.
- **Full-screen apps** — the mirror cannot float above a full-screen window (different Space).
- **Performance** — each pinned window runs an independent 60fps capture stream. Pinning many windows increases GPU usage.
- **Not on the App Store** — uses one private API (`_AXUIElementGetWindow`) and requires Screen Recording + Accessibility permissions that are incompatible with App Sandbox.

## License

MIT
