#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=15.0
cargo build --manifest-path core/Cargo.toml --release --offline
swift build -c release -Xlinker -L -Xlinker "$PWD/core/target/release" -Xlinker -lmnome_core
mkdir -p build/Mnome.app/Contents/MacOS
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
<key>NSAppleEventsUsageDescription</key><string>Mnome hides and restores the macOS menu bar.</string>
</dict></plist>
PLIST
codesign --force --sign - build/Mnome.app
printf 'Built %s/build/Mnome.app\n' "$PWD"
