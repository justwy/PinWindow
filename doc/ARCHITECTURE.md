# PinWindow Architecture

## API Inventory

### ScreenCaptureKit (macOS 12.3+)

The core of the app. Captures a single window's pixels at 60fps and streams them to an AVSampleBufferDisplayLayer.

| API | Min OS | Status |
|---|---|---|
| `SCContentFilter(desktopIndependentWindow:)` | 12.3 | Stable, Apple's recommended approach |
| `SCStream` / `startCapture` / `stopCapture` | 12.3 | Stable |
| `SCStream.updateConfiguration` | 12.3 | Stable |
| `SCShareableContent.getExcludingDesktopWindows` | 12.3 | Stable |
| `SCContentFilter.contentRect` / `.pointPixelScale` | 14.0 | Guarded with `#available(macOS 14, *)` |

**Fragility: Low.** This is Apple's strategic replacement for deprecated CGWindowServer APIs. Actively developed with new features each WWDC.

### Accessibility Framework (macOS 10.2+)

Used for two purposes: identifying the target window and tracking its position in real-time.

| API | Min OS | Purpose |
|---|---|---|
| `AXUIElementCreateApplication` | 10.2 | Get app reference by PID |
| `AXUIElementCopyAttributeValue` | 10.2 | Read focused/main window |
| `AXObserverCreate` / `AddNotification` | 10.4 | Watch for window move/resize/focus |
| `kAXWindowMovedNotification` | 10.4 | Event-driven position sync |
| `kAXWindowResizedNotification` | 10.4 | Event-driven size sync |
| `kAXApplicationActivatedNotification` | 10.4 | Re-check focus when the real window's app activates |
| `kAXApplicationDeactivatedNotification` | 10.4 | Re-check focus when the real window's app deactivates |
| `kAXFocusedWindowChangedNotification` | 10.4 | Show/hide mirror when focus moves between sibling windows of the same app |
| `AXIsProcessTrustedWithOptions` | 10.9 | Request permission |

**Fragility: Very low.** Foundation of macOS accessibility. Screen readers, enterprise tools, and automation depend on it. Apple has never broken backward compatibility.

### `_AXUIElementGetWindow` (Private, macOS 10.5+)

```swift
dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow")
```

Maps `AXUIElement` → `CGWindowID`. This is the bridge between the Accessibility world (which window is focused?) and ScreenCaptureKit (capture this window ID).

**Fragility: Medium-high.** No public replacement exists. Every window management tool in the ecosystem depends on it (Rectangle Pro, Magnet, Floaty, WinTop, BetterSnapTool). Apple is aware of this dependency. If they remove it, they would likely ship a public replacement in the same release.

The `dlsym` lookup pattern is defensive — returns nil instead of crashing if the symbol disappears.

### AVFoundation

| API | Min OS | Status |
|---|---|---|
| `AVSampleBufferDisplayLayer` | 10.8 | Stable |
| `.sampleBufferRenderer.enqueue()` | 15.0 | Current API |
| `.enqueue()` (direct) | 10.8 | Deprecated in 15.0, still works |

Both paths are handled with `#available(macOS 15, *)`.

### Carbon Event Hotkeys

```swift
RegisterEventHotKey / InstallEventHandler
```

**Fragility: High.** Deprecated since macOS 10.6. No Swift-native replacement for global hotkeys exists. Apple hasn't removed it because the entire ecosystem depends on it, but it's on borrowed time.

If Carbon is removed, only the hotkey convenience breaks — core pin/unpin functionality is unaffected (menu bar and CLI still work).

### AppKit (NSPanel, NSStatusBar)

Standard AppKit window management. `NSPanel` with `.floating` level, `.ignoresMouseEvents`, `.nonactivatingPanel`. All stable since macOS 10.0-10.6.

**Fragility: Very low.**

### CGWindowListCopyWindowInfo

Used in `syncFrame()` to read window bounds, and `checkAlive()` to detect window closure.

**Fragility: Medium.** Apple is steering toward ScreenCaptureKit for window enumeration. Could be deprecated or restricted. Both uses could be replaced:
- `syncFrame()` → read position via `AXUIElementCopyAttributeValue(kAXPositionAttribute/kAXSizeAttribute)`
- `checkAlive()` → use `AXUIElementCopyAttributeValue` and check for error

## Compatibility Matrix

| macOS Version | Support | Notes |
|---|---|---|
| 15+ (Sequoia/Tahoe) | Full | All APIs available, new renderer API used |
| 14 (Sonoma) | Full | Uses `pointPixelScale` for better sizing |
| 13 (Ventura) | Full | Falls back to `window.frame.width * 2` for sizing |
| 12.3 (Monterey) | Likely works | Not tested, SCK available but early |
| < 12.3 | Not supported | No ScreenCaptureKit |

## TCC (Permission) Landscape

| Permission | Required For | Trend |
|---|---|---|
| Screen Recording | ScreenCaptureKit capture | Getting stricter — Sequoia added periodic resets |
| Accessibility | AXObserver, window identification | Stable prompting model |

Apple's direction is toward more frequent permission re-authorization. The app should handle permission revocation gracefully (capture stops → mirror auto-removes).

## Known Limitations

1. **Fully obscured windows** — if the real window is completely covered, macOS may throttle its rendering. `AVSampleBufferDisplayLayer` keeps its last enqueued frame on screen on its own, so the mirror shows the last good frame without any extra fallback layer.

2. **Spaces** — the mirror panel uses `.canJoinAllSpaces` so it appears on all desktops. The real window only exists on one space. If the user switches spaces, the mirror shows but clicks go nowhere.

3. **Full-screen apps** — full-screen windows use a separate space. The mirror cannot float above a full-screen app.

4. **Performance** — each pinned window runs a 60fps SCStream capture, but `didOutputSampleBuffer` drops any frame whose `SCStreamFrameInfo.status` is not `.complete`. A static window sends almost no complete frames, so CPU use stays near zero until its content actually changes. The stream also slows to near-idle while the mirror is hidden behind the focused real window. Pinning many windows that are all actively changing at once will still increase GPU/CPU usage.

5. **First click still lands on whatever is under the mirror** — the panel ignores mouse events, so a click on it passes through to the real window only if the real window is directly underneath. If a different window covers the real window at that point on screen, that other window receives the click first.

6. **No automated tests** — this repo has no test target. Verify the focus-hide behavior manually: rapid focus flapping between sibling windows of the same app, and a focus change during the ~150ms resize debounce window.
