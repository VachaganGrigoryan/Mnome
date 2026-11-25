# Mnome UI standard

Use https://developer.gnome.org/hig/index.html for all Mnome-owned UI. The implementation uses Swift/AppKit rather than GTK; maintain shared ThemePalette, AdwaitaButtonStyle and semantic system typography rather than per-view custom palettes. Appearance defaults to System and allows Light and Dark overrides for Mnome windows (Preferences, Shortcuts, About); shell surfaces (top bar, Quick Settings, dash, overview) are always dark, like GNOME Shell. Colors come from `ThemePalette` (libadwaita named colors) and `ShellPalette`; lists use the shared boxed-list components (`PreferencesGroup`, `BoxedList`, `ActionRow`, `SwitchRow`, `CheckRow`, `ExpanderRow`, `StatusPage`, `Keycap`). Controls expose hover, focus, pressed and disabled states; high contrast adds outlines. No motion is required for state changes.

Overview: GNOME's (gnome-ref/shell/005, 017, 024): #222226, the work area at 72% as a rounded (30) wallpaper workspace, the next one at 94% peeking 64 px away, windows laid out by OverviewLayout (rows by centre, boost 1.5→1, cap 0.95), app icon over each window's bottom edge, search entry 370×37 #45454a, dash #38383b; one progress value animates everything 250 ms ease-out-quad, workspace slides ease-out-cubic; app grid 8 columns in pages with dots; search sections in #38383b boxes. Non-activating key panels, so the keyboard returns by itself.

Use GNOME Ctrl accelerators scoped to Mnome focus; preserve macOS reserved keys and input composition. Every action requires keyboard access and an accessible name. Keep focus during live app updates; Escape closes the nearest transient surface.

Platform adaptations: native application icons and system fonts; macOS permission dialogs remain native. The native Mnome status menu remains a recovery route with Quit. The shell status popover includes Quit because Mnome is a persistent shell. Desktop panels overlay content without reserving workspace; fullscreen behavior requires manual verification. Test keyboard-only, VoiceOver, high contrast, enlarged text, reduced motion, long labels and multiple display scales. Do not report unavailable GUI checks as passing.

## Bundled symbolic asset

`Sources/Mnome/Resources/open-menu-symbolic.svg` is from GNOME/adwaita-icon-theme (`Adwaita/symbolic/actions/open-menu-symbolic.svg`). The unmodified upstream `COPYING` is bundled as `Adwaita-COPYING`. Upstream offers LGPL v3 or CC BY-SA 3.0 US; preserve attribution and license when redistributing. The resource remains vector-based; no generated bitmap is used.

Hiding macOS shell elements is per element (Dock and menu bar by default, desktop and Stage Manager opt-in) and always reversible: Restore All stays reachable from Preferences and the native status menu.
