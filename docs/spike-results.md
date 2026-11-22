# Phase 1 spike results

macOS 27.0.1 (26A434), 22 November 2026. Built-in display 1512×982 pt (notch, safe top 32) with a 1920×1080 display to its right, bottom edges aligned. The throwaway code became `./scripts/live-tests.sh 1`. Every test used windows created for it; no other app's windows and no system setting were changed.

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

## Live tests with the person present

| Test | Result | Consequence |
|---|---|---|
| Phase 0 fixes in the running app | Typing reaches search, Esc returns focus, clicking raises the right window (checked by the person) | |
| Park real windows | Microsoft Edge and Outlook, 1512×948: 6–11 ms, 1×41 and 1×32 pt visible, captured while parked, restored exactly on the first try, no drift | Parking stands. Coverage is thin: two windows, one per app |
| Hide the menu bar without Automation | `_HIHideMenuBar` plus `AppleInterfaceMenuBarHidingChangedNotification` hid it on both displays within 3 s; restored exactly | Use this route first |
| `visibleFrame` while hidden | Fresh process: built-in top gap 32 (the notch strip), external 0. A process already running kept reporting 34 and 31 | On the notched display windows already stay below a 32 pt bar. On others the window manager must keep them below it. Never trust `visibleFrame` in the process that hid the bar |
| Bar level | Level 3 is pushed down. 24, 25 and 26 stay at the top edge and received 2 of 2 clicks on each display, on both sides of the notch (simulated clicks). No invisible window took clicks | |
| Pointer pushed to the top edge | Level 24: the Mac menu bar appears over ours. 25 and 26: ours stays on top and the Mac menus cannot be reached | **Use level 24** |
| Right Command+Tab, real keyboard | Session tap caught it every time, before the Dock: no app switcher, no app change (5 presses over two runs; the first run's detector was unreliable, the second had a working left Command+Tab control). Lone right Command detected once, no false taps. macOS never disabled the tap | Use the session tap. The symbolic-hotkey fallback is not needed |
| Dark style | `SLSSetAppearanceThemeLegacy` switched and restored, as macOS reports it | Toggle. Not tried with automatic appearance on |
| Night Light | `CBBlueLightClient setEnabled:` switched and restored. Status layout `BBBi{ii}{ii}QB`; read the second byte (`enabled`), `active` was true while off | Toggle. Not tried with a schedule |

## Still open

1. ~~Parking apps with several windows, terminals and Electron editors.~~ TextEdit (two windows), Terminal and VS Code park to 1×32 pt and return exactly (`./scripts/live-tests.sh apps`).
2. Setting Bluetooth and Wi-Fi.
3. Display unplug, sleep and wake while windows are parked. ~~Journal entries whose app restarted~~ (`./scripts/live-tests.sh 2`).

## Decision

Parking, matching, capture, crash recovery, the key tap and the top bar all hold on 27.0.1. Phases 2 to 5 go as planned, with the bar at level 24. Workspaces stay off by default until open item 3 passes.
