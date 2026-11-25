# Changelog

## 1.0.0 — 2026-11-25

The first release: GNOME Shell on macOS 27, with SIP on.

### Top bar
- GNOME's bar on every display: Activities with workspace dots, the clock with the calendar and the day's events, the status pill with Quick Settings, GNOME's power dialogs, and GNOME's level pill for the volume and brightness keys.
- The front app's real menus next to Activities, at the Mac's own positions, opening on mouse-down and switching as you slide across them.
- The apps' menu bar icons, drawn by Mnome as GNOME's app indicators.
- Rearrangeable: Command-drag, or Preferences → Shell → Top Bar (clock in the middle or on the right).
- Or the Mac's own menu bar with Mnome's items in it.
- Run a Command (Option+F2), light and dark styles in Adwaita.

### Overview and app grid
- GNOME's overview on the GPU: windows glide onto the workspace, the next workspace peeks in, search for apps, windows, settings, files and sums.
- The app grid in pages, with folders.

### Windows and workspaces
- A window manager with a stateless Rust core; workspaces that park windows safely on disk first.
- GNOME's shortcuts on Super (Right Command), Alt+Tab, edge tiling by dragging with a preview, resizing two tiles at once, the hot corner, the workspace slide.

### Trackpad
- Three-finger gestures that follow the fingers: overview, app grid, workspaces.

### The Mac
- Only Mnome: the Mac's Dock, menu bar, desktop, Stage Manager, Mission Control, hot corners, animations, tiling and status icons off while Mnome runs, back when it quits.
- Mnome's own desktop; Ctrl+↑/↓ open the overview and app grid.
- The Mac's Dock, if kept, with GNOME's Show Applications and as the overview's dash.
- Recovery: everything is restored on quit, after a crash, or with `--rescue`; Bring Back All Windows.

### Checked
- `swift test` (112 tests), `cargo test` (46), clippy, fmt, `--self-test`.
- `./scripts/live-tests.sh` on macOS 27 with two displays (a notched built-in and an external 1x): parts 1, 2, apps and 3 pass. Part 2's "a window moved while away goes back" failed once on timing and passed on re-run.
- By hand: the app menus in the bar (open, slide across, close).
- Not yet by hand: trackpad gestures, folders, the Mac Dock tile, Command-drag (see the GUIDE's manual checks).

### Known limits
See the README.
