# Mnome

A GNOME-inspired macOS launcher and window overview, built with a Rust core and a Swift/AppKit host. Requires Apple Silicon, macOS 15+, Xcode and Rust. SIP stays enabled.

## Build

Run `./scripts/build.sh` from this directory. The locally ad-hoc signed app is `build/Mnome.app`. Launch it in Finder. Cargo dependencies must already be cached for the offline build; otherwise run `cargo fetch --manifest-path core/Cargo.toml` first.

The Swift host owns application discovery, UI, capture and Accessibility objects. Rust ranks application searches and computes overview layouts through a versioned JSON C ABI. Swift copies Rust response bytes and releases them using Rust's free function.

Window previews require Screen Recording permission; window control requires Accessibility permission in System Settings. Application launching remains available without these permissions. Rebuilding with an ad-hoc signature may require granting permissions again.

Only eligible onscreen windows are included. Hidden and minimized windows are excluded. Public APIs cannot reliably join every captured window to an Accessibility window: ambiguous selections activate the owning app instead. Stage Manager and fullscreen behavior require manual verification. Previews are snapshots, not continuous streams.

## Validation

- `cargo fmt --manifest-path core/Cargo.toml --check`
- `cargo clippy --manifest-path core/Cargo.toml --offline --all-targets -- -D warnings`
- `cargo test --manifest-path core/Cargo.toml --offline`
- `./scripts/build.sh`

Manual acceptance: launch and dismiss with the keyboard, search and open an app, select a window, deny each permission, close a window during capture, test duplicate titles, multiple displays, mixed scales and fullscreen/Stage Manager. macOS 15 compatibility needs a host running that version. Developer ID signing and notarization are not included.

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
