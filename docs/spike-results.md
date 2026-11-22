# Phase 1 spike results

macOS 27.0.1 (26A434), 22 November 2026. Built-in display 1512×982 pt (notch, safe top 32) with a 1920×1080 display to its right, bottom edges aligned. Throwaway code, not in the repository. Every test used windows created for it; no other app's windows and no system setting were changed.

## Answered

| Question | Result | Consequence |
|---|---|---|
| Park in a corner | 5 of 6 windows parked bottom-left. macOS keeps the title bar on screen, so asking for y = 981 gave y = 950: a **1 × 32 pt** sliver. 6–18 ms per window | Use parking. The parked y is whatever reads back, never the requested one |
| Windows that refuse | One window moved itself back on screen. The Accessibility call still returned success | Always read back. Such a window needs another hiding method |
| Exact restore | 6 of 6 exact | |
| Exact matching | `_AXUIElementGetWindow` returned the right number for all 6, including two with the same title | Use it; title and frame matching is the fallback |
| Capture while parked | All 6 in full, correct colours, 15–78 ms each at 210×154. ScreenCaptureKit reports parked windows as on screen | Live thumbnails for every workspace |
| Crash recovery | Controller killed with SIGKILL after parking, positions confirmed parked, new process restored from the journal: identical to before | Gate passed, for a surviving app with unchanged window numbers |
| Right Command | An active session tap sees key 54 with device flag 0x10 (left is 0x8), swallows a chosen chord and passes the rest. Events were synthetic | Use the tap |
| Volume | Readable, reported settable | |
| Brightness | Built-in: get and set (same value) succeed. External: unsupported (1000) | Hide the slider for displays that refuse |
| Bluetooth, dark style, Wi-Fi power, Night Light | State readable / class present. **Setting was not tried** | |
| Wi-Fi name | Hidden without Location permission | Show "Wi-Fi" until granted |

## Still open: needs the person at the Mac

1. Parking real apps (Electron, browsers, Terminal, apps with several windows).
2. The bar on the notched display with the menu bar hidden: `visibleFrame`, and whether the hidden MenuBarAgent window eats clicks.
3. Right Command+Tab before the Dock sees it, with a real keyboard.
4. Setting Bluetooth, Wi-Fi, dark style and Night Light.
5. Display unplug, sleep and wake while windows are parked; journal entries whose app restarted.
