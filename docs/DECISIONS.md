# Decisions

Why Mnome is the way it is, one decision at a time. Newest last.

## 1. SIP stays on

Mnome must run on an ordinary Mac. So no code is injected into the Dock, WindowServer or other apps, no kernel extension, nothing that needs System Integrity Protection off. What macOS does not let an app change (the Apple menu, the Mac's clock and Control Center icon) stays as macOS draws it.

## 2. Right Command is Super

GNOME is driven by Super. Left Command belongs to the Mac's own shortcuts, so Right Command (or Right Option, in Preferences) becomes Super, and only GNOME's listed combinations are taken; everything else reaches apps untouched.

## 3. A stateless core

Where windows belong is decided in Rust as a pure function: the whole state and one event in, the new state and a list of operations out. Swift keeps the state, carries out the operations through Accessibility, and reads every result back. The rules can be tested without a Mac, and a crash loses no decision.

## 4. Never lose a window

Windows of other workspaces are parked out of sight, and each one's frame is written to disk before it moves. Records are deleted only once the window is back in sight or gone for good, so a crash, a hung app or a lock screen cannot strand a window.

## 5. Private calls only with a runtime lookup and a fallback

A few features exist only behind private frameworks (trackpad frames, Spaces, Dock auto-hide, brightness, dark style, Bluetooth, Night Light). Each is looked up when needed; when a macOS update removes one, that feature goes quiet and Mnome keeps running. They are listed in [ARCHITECTURE](ARCHITECTURE.md).

## 6. The look from GNOME, not its code

GNOME Shell is GPL JavaScript and CSS for a different toolkit. Mnome reproduces its behaviour and look from GNOME's own screenshots and specs, and bundles only GNOME's unmodified Adwaita font and symbolic icons, under their own licences. Mnome itself is GPL-3.0-or-later, as GNOME is.

## 7. Replace the Mac's shell rather than restyle it

macOS lets apps hide the Dock, menu bar, desktop, Mission Control and the rest, but not restyle them. So Mnome hides each part (saving the original settings first, restoring them on quit) and draws GNOME's version in its place.

## 8. Exception: the Mac's own Dock, if wanted

The Mac Dock's launch and minimize animations cannot be reproduced by another app. Kept, it gets GNOME's Show Applications tile and serves as the overview's dash.

## 9. App menus are the real menus

The front app's menu titles are shown in Mnome's bar exactly where the hidden Mac menu bar has them, and a click presses the real title. The app's own menu opens, with its own items, states and shortcuts; nothing is copied, and macOS's own menu tracking lines up with Mnome's titles.

## 10. App icons are captured

macOS 27 draws every app's menu bar icon in one system process and gives other apps only their positions. The only way to show them in Mnome's bar is to copy their pictures from the hidden Mac menu bar (Screen Recording) and pass clicks on.
