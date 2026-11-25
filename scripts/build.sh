#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=15.0
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~" # the builder's home folder stays out of the binary
cargo build --manifest-path core/Cargo.toml --release --offline
swift build -c release -Xlinker -L -Xlinker "$PWD/core/target/release" -Xlinker -lmnome_core
mkdir -p build/Mnome.app/Contents/MacOS
rm -f build/Mnome.app/Contents/MacOS/Mnome # a new file: overwriting the one a running Mnome uses would kill it
cp .build/release/Mnome build/Mnome.app/Contents/MacOS/Mnome
mkdir -p build/Mnome.app/Contents/Resources
cp Sources/Mnome/Resources/Mnome.icns build/Mnome.app/Contents/Resources/Mnome.icns
for bundle in .build/release/*.bundle; do
  if [ -d "$bundle" ]; then cp -R "$bundle" build/Mnome.app/Contents/Resources/; fi
done
cat > build/Mnome.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.mnome.shell</string>
<key>CFBundleName</key><string>Mnome</string>
<key>CFBundleIconFile</key><string>Mnome.icns</string>
<key>CFBundleExecutable</key><string>Mnome</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Mnome hides and restores the macOS menu bar, and asks macOS to suspend, restart, power off or log out when you choose it in Quick Settings.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Mnome shows whether Bluetooth is on and switches it from Quick Settings, as GNOME does.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Mnome shows the day's events in the calendar under the clock, as GNOME does. Nothing leaves your Mac.</string>
</dict></plist>
PLIST
# GNOME's Show Applications for the Mac Dock: a tiny app that tells Mnome to open its app grid.
helper="build/Mnome.app/Contents/Library/Show Applications.app"
rm -rf "$helper"; mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
swiftc -O Helpers/ShowApplications.swift -o "$helper/Contents/MacOS/ShowApplications"
iconset="$(mktemp -d)/AppGrid.iconset"; .build/release/Mnome --make-app-grid-icon "$iconset"; iconutil -c icns "$iconset" -o "$helper/Contents/Resources/AppGrid.icns"; rm -rf "$(dirname "$iconset")"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.mnome.show-applications</string>
<key>CFBundleName</key><string>Show Applications</string>
<key>CFBundleDisplayName</key><string>Show Applications</string>
<key>CFBundleIconFile</key><string>AppGrid.icns</string>
<key>CFBundleExecutable</key><string>ShowApplications</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${MNOME_SIGN_ID:--}" "$helper"
# An ad-hoc signature changes every build, so macOS forgets permissions; a fixed identity keeps them.
codesign --force --sign "${MNOME_SIGN_ID:--}" build/Mnome.app
printf 'Built %s/build/Mnome.app\n' "$PWD"
