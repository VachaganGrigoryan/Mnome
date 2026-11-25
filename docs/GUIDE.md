# Mnome in detail

How each part of Mnome works, what it needs and what it leaves alone. The overview is in the [README](../README.md); how it is built is in [ARCHITECTURE](ARCHITECTURE.md), and why in [DECISIONS](DECISIONS.md).

## Permissions

- **Accessibility**: window control, the keyboard shortcuts, the app menus and app icons in the bar. Without it Mnome still launches apps.
- **Screen Recording**: window pictures in the overview and switcher, the workspace slide, and the apps' menu bar icons. Without it the overview shows app icons and switching workspace does not slide.
- **Calendar**: asked the first time the calendar menu shows a day's events.
- `open -n -W --stdout FILE build/Mnome.app --args --permissions` writes what Mnome has been granted to FILE.
- An ad-hoc signed rebuild may lose the permissions. To keep them, create a self-signed *Code Signing* certificate in Keychain Access (Certificate Assistant) and build with `MNOME_SIGN_ID="<certificate name>" ./scripts/build.sh`.

## Top bar

- GNOME's 32-point bar on every display, in place of the Mac's menu bar, which stays hidden under it. Text is Adwaita Sans and the icons are Adwaita's symbolic set, both bundled (`Sources/Mnome/Resources/ADWAITA-PROVENANCE.md`).
- **Activities** shows one dot per workspace, the current one a wide pill; a click opens or closes the overview.
- **The clock** shows the date and time as GNOME does, in your locale's order. A click (or Super+V) opens GNOME's calendar: the month (weeks start as your region does) and the chosen day's events from Calendar.
- **The status pill** shows the network (Wi-Fi strength or wired), volume and battery, or a power icon without a battery; it opens **Quick Settings**: screenshot, System Settings, lock and power buttons; volume and brightness sliders; Wi-Fi, Bluetooth, Night Light, Dark Style and Keep Awake; and a Mnome toggle with Mnome's own settings. Do Not Disturb and Power Mode are not there: macOS lets apps change neither. The network status does not guarantee internet access.
- **Power**: Suspend acts at once; Restart, Power Off and Log Out ask first and act by themselves after 60 seconds, as GNOME does.
- **Level pill**: the volume, mute and brightness keys show GNOME's pill instead of the Mac's. Option with them still opens the Mac's settings; outputs without their own volume, and external displays, stay the Mac's.
- **Appearance**: the bar and Quick Settings follow Preferences → Appearance (light or dark, as GNOME 47); the dash, overview and switchers stay dark, and Increase Contrast strengthens the highlights.
- **The app's menus**: with Mnome's bar, the front app's name in bold and its titles follow Activities, each exactly where the Mac's hidden menu bar has it, on the display that menu bar is on. A press (on mouse-down, as on the Mac) presses the Mac's own title through Accessibility, so the app opens its real menu right under it; once it is open, sliding across the titles switches menus as on the Mac, and a second click closes it. While the menus show, Activities takes the Apple menu's place (its dots shrink to fit). The Apple menu itself is left out, and titles that would reach the next item are dropped, as the Mac drops them at the notch. The titles are read again when the app or the Space changes; a window moved to the other display keeps its titles where they were until then.
- **The apps' icons**: before the status pill, as GNOME's app indicators. macOS 27 draws every app's menu bar icon in one system process (MenuBarAgent) and tells Accessibility only where each one is, so Mnome hides the Mac's own Wi-Fi, Bluetooth, Sound and similar icons, cuts the rest out of a capture of the hidden Mac menu bar every 2 seconds, and passes a click on to the icon, which opens the app's menu where the Mac would. The Mac's Control Center and clock (always the two rightmost) and Mnome's own item are left out. An icon that changes lags up to 2 seconds.
- **Rearranging**: hold Command and drag Activities, the clock or the status pill to the left, middle or right third of the bar; Preferences → Shell → Top Bar puts the clock in the middle or on the right, orders the right side, and resets GNOME's layout. Menus open under their item wherever it is.
- **The Mac's menu bar instead** (Preferences → Shell → Panels): the app's menus stay on the left (the Apple menu cannot be changed), the Mac's Wi-Fi, Bluetooth, Sound, Battery, Display, Screen Mirroring and user icons are hidden, and Mnome adds Activities (right click for Mnome's menu), the date (the calendar) and the status pill. The Mac's clock and Control Center icon cannot be hidden: the clock keeps only the time beside Mnome's date. App icons stay.
- **Run a Command** (Option+F2, with Fn on a Mac keyboard): an application's name opens it, anything else runs in your login shell, Up and Down go through earlier commands, and `r` restarts Mnome.

## Overview and app grid

- Opens on every display from Super (Right Command), the Mission Control key, Ctrl+↑, the Activities dots, the hot corner, three fingers up, or Control–Option–Space.
- The windows glide from where they are onto the workspace, drawn on your wallpaper, with the next workspace peeking in at the side, the search entry at the top and the dash at the bottom. Windows and workspaces are Core Animation layers moved on the GPU; SwiftUI draws only the search, results, app grid and dash.
- Click a window to go to it, the wallpaper to leave, another workspace to switch to it, or drag a window onto one to move it there. Scrolling, swiping, Super+Option+←/→ and Ctrl+←/→ move between workspaces inside the overview; it stays up until the windows have stopped moving. Hovering a window shows its title and a close button.
- Typing searches applications, open windows, System Settings, files (Spotlight, in your home folder) and sums (Return copies the answer); arrows and Return pick, Escape clears the search and then closes.
- The overview takes the keyboard without making Mnome the active app, so closing it leaves you where you were. Other displays show their own windows only, as workspaces are on the main display.
- **The app grid** (Super+A, Ctrl+↓, the Launchpad key, the dash's grid button) shows apps in pages, with GNOME's **folders**: drop an app on another to make one, on a folder to add it, drag it out of the open folder (or use its menu) to take it out, and click the name to rename it. It starts with a Utilities folder. Arrow keys do not move inside an open folder yet.
- **The dash** is the overview's: favorites, then other running apps, and Show Applications. First use seeds Finder, Safari, Terminal and System Settings; pin or unpin through an app's menu, drag pinned apps to reorder, Quit from a running app's menu. Favorites (and an intentionally empty list) are kept; a missing app stays saved until removed. A copy on the desktop is off unless Dock is turned on in Quick Settings → Mnome or Preferences → Shell; it overlays content without resizing windows, and overflow scrolls.
- `defaults write dev.mnome.shell overviewTiming -bool true` logs each opening's timing; `.build/debug/Mnome --overview-check` opens and closes the running Mnome's overview and prints them.

## Windows and workspaces

- With Accessibility, Mnome tracks every app's standard windows through Accessibility notifications, checks each fact by reading it back, and sweeps every 30 seconds as a backup. The Rust core decides where windows belong; Swift carries it out, retries, and never waits on an app. Windows in native full screen are left alone.
- **Workspaces**: windows of other workspaces are parked in a free bottom corner of the main display. Before a window is parked its frame is written to `~/Library/Application Support/Mnome/parked.json`; a record is deleted only once its window is back in sight, its app has ended, or macOS no longer knows the window, so a window an app closes while parked and opens again returns where it was. Parked windows return when Mnome quits, at the next launch after a crash, with **Bring Back All Windows** (status menu, Preferences → Shell), or with `Mnome --rescue` while Mnome is not running. One copy of Mnome manages windows at a time.
- While the screen is locked or asleep, or another user is in front, Mnome ignores what macOS reports about windows, and afterwards puts back what macOS moved. An app that does not answer during a switch is asked again later instead of having its windows shown everywhere.
- **Focus**: typing never reaches a window out of sight; focus is read back, and on an empty workspace Mnome itself holds the keyboard. When macOS gives the keyboard to a parked window by itself (a window closed, minimized or hidden, an app quit) the workspace stays; when you choose it (Dock, Cmd+Tab) the workspace follows.
- Workspaces turn off by themselves while Stage Manager is on or no display corner is free. They live in one Mac desktop (Space) per display: if a display has more, the calendar menu says so and Preferences → Shell → Remove Extra Mac Desktops brings Mission Control back until only one is left.
- **Switching** slides the screen as GNOME does (not with Reduce Motion, or without Screen Recording). A key pressed during a slide switches without a slide of its own. A row of dots shows where you are.
- **Keyboard**: Right Command is Super; tapped alone it opens or closes Activities, with another key it runs GNOME's shortcuts (Keyboard Shortcuts lists them; Preferences → Keyboard changes them or makes Right Option the Super key). Only the listed combinations are taken: every other Right Command combination, and all of Left Command, reaches apps untouched. Shortcuts are physical keys, so they stay put when the layout changes. Super+Option+←/→ (or Super+Page Up/Down) switch workspace, with Shift they take the window along, Super+Home/End go to the first and last. Listening stops while macOS protects a password field (Control–Option–Space still opens Activities then); no key is stored or logged. Shortcuts act on the window in front, and do nothing on a dialog or a window Mnome does not track.
- **Switcher**: Option+Tab or Super+Tab switches applications as GNOME does (Shift goes back, the key above Tab cycles one app's windows, Escape cancels, letting go chooses); Left Command+Tab opens it too (Preferences → Keyboard can give that back to the Mac), and Preferences → Keyboard chooses all workspaces or the current one.
- **Edge tiling**: drag a window to the left or right edge for half the screen, into a corner for a quarter, or to the top to maximize it; an accent preview shows where it will go, and dragging it away gives it its size back. Dragging the edge two tiles share resizes both.
- **Hot corner**: pushing the pointer into the top-left corner opens or closes the overview (not over a full-screen app).
- Preferences → Shell turns off Edge Tiling, the Hot Corner and Trackpad Gestures.

## Trackpad

- Three fingers up open the overview and then the app grid, down go back, sideways switch workspace; the overview and the slide follow the fingers, and letting go past half way, or a flick, finishes.
- The Mac's own three-, four- and five-finger swipes are off while Mnome runs (with Mission Control). Three-finger drag, an Accessibility setting, would take these swipes and is left to you.
- Trackpads are found at launch and after waking; one connected later is found at the next wake.

## The Mac, replaced or adapted

- **Only Mnome** (Quick Settings → Mnome, on by default): while Mnome runs, the Mac's Dock, menu bar, desktop icons and widgets, Stage Manager and click-to-show-desktop, Mission Control and its gestures, hot corners, window animations, edge tiling and status icons are off. Preferences → Shell → macOS turns each on or off, and the choice is kept. The Dock, Finder, WindowManager and Control Center restart briefly when one is changed. Before macOS 27, hiding the menu bar asks for Automation (System Events) the first time.
- **Mnome's desktop**: with the Mac's desktop hidden, Mnome draws the wallpaper behind every app; a click there changes nothing, a right click offers Change Background, Display Settings and Settings.
- **Mission Control keys**: Ctrl+↑ and Ctrl+↓ open Mnome's overview and app grid. On macOS 27 Mission Control ignores the old switch, so Mnome also turns off its four- and five-finger gestures.
- **The Mac's own Dock** (Preferences → Shell, Hide Dock off, Mnome's dock off): it gets GNOME's Show Applications, last after the separator before Trash, which opens Mnome's app grid (or starts Mnome). Minimized windows and launches animate with the Dock's real icons. Mnome puts the tile back at each launch and takes it away when it quits. In the overview the Dock takes the dash's place: it slides up while the overview is open, even with auto-hide on (switched back when it closes, or at the next launch after a crash); windows stay where they are, and opening an app from it closes the overview.

## Recovery

- Everything Mnome changes on the Mac is saved first and put back when it quits normally.
- After a crash the saved originals stay on disk: relaunch Mnome and quit it normally, run `build/Mnome.app/Contents/MacOS/Mnome --rescue`, use **Restore macOS Shell** in the status menu, or Preferences → Shell → Restore All macOS Settings. The **macOS Shell** pill in Quick Settings and Restore All bring everything back and keep it that way.
- Parked windows: see Windows and workspaces.

## Testing

- **The gate**: `cargo fmt --check`, `cargo clippy --offline --all-targets -- -D warnings` and `cargo test --offline` in `core/`; `cargo build --release` there, then `swift test` (it links the release core); `./scripts/build.sh`, then `build/Mnome.app/Contents/MacOS/Mnome --self-test`.
- `Mnome --gallery DIR` renders the shell's panels to PNG without opening windows.
- `./scripts/live-tests.sh` drives the real Mac for about 4 minutes, keyboard and mouse included, and quits and reopens Mnome as needed. Run it after a macOS update or a change to windows, keys or the bar. Names run parts: `1` what macOS allows (parking, capture, the key tap, the bar's place, system controls), `2` the window engine, `apps` the engine on fresh copies of TextEdit, Terminal and VS Code, `3` keys, snapping, workspaces, Alt+Tab and the hot corner in the running app, and `drag` (only on request) edge tiling with the real mouse. It moves only windows of its own, except that `3` minimizes every window for a moment and checks each returns exactly. `1` switches dark style, Night Light and the menu bar briefly and puts them back, also after being interrupted (`.build/debug/Mnome --system-check rescue` does so by hand). A `skip` line was not tested. The terminal needs Accessibility, and Screen Recording for captures.

### Manual checks

Things only a person can judge. Last full pass: see the CHANGELOG.

- Keyboard: open and close Activities with Super, search and open an app, pick a window, Super+A, Escape.
- Each permission denied in turn: Mnome still launches apps.
- Windows: close one during a capture, duplicate titles, several displays with mixed scales, a full-screen app, Stage Manager on.
- Bar: notched and external displays, a display reconnecting, sleep and wake (the clock), network and battery changes, light and dark.
- App menus: click a title, slide across the titles, click the open title again, Format → Font in TextEdit; an app icon's menu.
- Command-drag the clock to the right and back; Preferences → Shell → Top Bar.
- Trackpad: three fingers up, down and sideways, slowly and with a flick.
- Folders: make one, rename it, drag an app out.
- The Mac Dock mode: the Show Applications tile, the Dock in the overview.
- macOS 15 needs a host running that version; Developer ID signing and notarization are not included.
