# Mnome

A GNOME-inspired macOS launcher and window overview, built with a Rust core and a Swift/AppKit host. Requires Apple Silicon, macOS 15+, Xcode and Rust. SIP stays enabled.

## Build

Run `./scripts/build.sh` from this directory. The locally ad-hoc signed app is `build/Mnome.app`. Launch it in Finder. Cargo dependencies must already be cached for the offline build; otherwise run `cargo fetch --manifest-path core/Cargo.toml` first.

The Swift host owns application discovery, UI, capture and Accessibility objects. Rust ranks application searches and computes overview layouts through a versioned JSON C ABI. Swift copies Rust response bytes and releases them using Rust's free function.

Window previews require Screen Recording permission; window control requires Accessibility permission in System Settings. Application launching remains available without these permissions. Rebuilding with an ad-hoc signature may require granting permissions again. To keep them, create a self-signed *Code Signing* certificate in Keychain Access (Certificate Assistant) and build with `MNOME_SIGN_ID="<certificate name>" ./scripts/build.sh`.

Only eligible onscreen windows are included. Hidden and minimized windows are excluded. Public APIs cannot reliably join every captured window to an Accessibility window: ambiguous selections activate the owning app instead. Stage Manager and fullscreen behavior require manual verification. Previews are snapshots, not continuous streams.

## Validation

- `cargo fmt --manifest-path core/Cargo.toml --check`
- `cargo clippy --manifest-path core/Cargo.toml --offline --all-targets -- -D warnings`
- `cargo test --manifest-path core/Cargo.toml --offline`
- `cargo build --release --manifest-path core/Cargo.toml --offline`, then `swift test` (it links the release core)
- `./scripts/build.sh`, then `build/Mnome.app/Contents/MacOS/Mnome --self-test`
- `build/Mnome.app/Contents/MacOS/Mnome --gallery DIR` renders the shell surfaces to PNG without opening windows
- `open -n -W --stdout FILE build/Mnome.app --args --permissions` writes Mnome's own permissions to FILE
- `./scripts/live-tests.sh` drives the real macOS for about 4 minutes, keyboard and mouse included, and quits and reopens Mnome as needed. Run it after a macOS update or a change to windows, keys or the bar. Pass names to run some: `1` what macOS allows (parking, capture, the key tap, the bar's place, system controls), `2` the window engine, `apps` the engine on fresh copies of TextEdit, Terminal and VS Code, `3` keys and snapping in the running app. It moves only windows of its own, except that `3` minimizes every window for a moment and checks each returns exactly. `1` switches dark style, Night Light and the menu bar briefly and puts them back, also after being interrupted; `.build/debug/Mnome --system-check rescue` does so by hand. A `skip` line was not tested. The terminal needs Accessibility, and Screen Recording for captures.

Manual acceptance: launch and dismiss with the keyboard, search and open an app, select a window, deny each permission, close a window during capture, test duplicate titles, multiple displays, mixed scales and fullscreen/Stage Manager. macOS 15 compatibility needs a host running that version. Developer ID signing and notarization are not included.

## Window engine

With Accessibility granted, Mnome tracks every app's standard windows through Accessibility notifications, checks each fact by reading it back, and sweeps every 30 seconds as a backup. The Rust core decides where windows belong (`wm` operation, see `core/README.md`); Swift carries it out, retries, and never waits on an app. Windows on native full screen are left alone and Stage Manager is not supported.

Windows of other workspaces are parked in a free bottom corner of the main display. Workspaces are not in the interface yet. Before a window is parked its frame is written to `~/Library/Application Support/Mnome/parked.json`, and the record is deleted only after the window has been read back in sight. Parked windows return when Mnome quits, at the next launch after a crash, through **Bring Back All Windows** (status menu and Preferences → Shell), or with `build/Mnome.app/Contents/MacOS/Mnome --rescue` while Mnome is not running. One copy of Mnome manages windows at a time. While the screen is locked or asleep, or another user is in front, Mnome ignores what macOS reports about windows; afterwards it puts back what macOS moved. A record is deleted only once its window is back in sight, its app has ended, or macOS no longer knows the window, so a window an app closes while parked and opens again returns where it was. An app that does not answer during a switch is asked again later instead of having its windows shown everywhere. Typing never reaches a window out of sight: focus is read back, and on an empty workspace Mnome itself holds the keyboard. When macOS gives the keyboard to a parked window by itself (after a window closes, is minimized or hidden, or its app quits) the workspace stays; when the person chooses it (Dock, Cmd+Tab) the workspace follows. Workspaces turn off by themselves while Stage Manager is on or no display corner is free.

The engine is tested live (Validation, above).

## Keyboard

Right Command is Super: tapped alone it opens or closes Activities, and with another key it runs GNOME's shortcuts (Keyboard Shortcuts lists them, Preferences → Keyboard changes them or makes Right Option the Super key). Only the listed combinations are taken; every other Right Command combination, and all of Left Command, reaches apps untouched. Shortcuts are physical keys, so they stay in place when the keyboard layout changes.

Listening needs Accessibility and stops while macOS protects a password field; Control–Option–Space still opens Activities then. No key is stored or logged. Shortcuts act on the window in front, and do nothing when that is a dialog or a window Mnome does not track.

## Top bar

Mnome displays a 32-point GNOME-inspired bar beneath the native menu/notch region on each display. Activities toggles the overview; the center shows local date/time, and the Quick Settings popover includes network and battery toggles, top bar/dock switches, shortcut and favorites sections, and System Settings links. Status does not guarantee internet connectivity.

Use **Show Top Bar** in Quick Settings or Preferences → Shell to hide or restore the bars. They overlay normal application content without reserving workspace or resizing windows. Closing the overview leaves the bars running. Apple’s menu-bar settings are unchanged.

Additional manual acceptance: verify bar placement on notched and external displays, display reconnects, visibility persistence across restart, Activities toggling, sleep/wake clock refresh, network changes, battery/charging updates, keyboard access, native menus and fullscreen behavior. GUI checks require an interactive session.

## Dock and favorites

The bottom dock displays favorites followed by other running user applications on each display. First use seeds installed Finder, Safari, Terminal and System Settings. The trailing Show Applications button opens the launcher. Pin to Dash or unpin through application context menus; drag pinned entries to reorder. Favorites and an intentionally empty list persist across restarts. Missing applications remain saved and can be removed through the favorites menu.

Click to launch or activate; context menus offer normal Quit for running applications. Show Dock in Quick Settings or Preferences → Shell controls visibility independently of the overview. The dock overlays content without resizing other windows or modifying Apple's Dock preferences. Overflow scrolls horizontally.

Manual acceptance: pin from launcher, reorder favorites, restart, launch/activate/quit, unavailable favorites, multiple processes, overflow, display reconnects and fullscreen coexistence. Interactive checks are required before claiming GUI behavior verified.

## Testing Mnome as the shell

Preferences → Shell → macOS (and the **macOS Shell** pill in Quick Settings) can hide Apple's Dock, menu bar, desktop icons and widgets, and Stage Manager / click-to-show-desktop, one element at a time. Mnome saves each original preference value before changing it and restores it exactly (including keys that were not set).

Original settings come back automatically when Mnome quits normally. If Mnome quits unexpectedly, the saved originals stay on disk: relaunch Mnome and use **Restore macOS Shell** in the status menu, or Preferences → Shell → Restore All macOS Settings. Hiding the menu bar asks for Automation (System Events) permission the first time. The Dock, Finder and WindowManager restart briefly when toggled.
