#!/bin/bash
# Wrap the SwiftPM executable in a .app bundle.
#
# A bare SwiftPM binary has no Info.plist, so macOS gives it no Dock icon,
# no proper menu bar and no ⌘Q. The bundle is what makes it behave like an
# application rather than a command-line tool that happens to open a window.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/CutSim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/CutSimApp" "$APP/Contents/MacOS/CutSim"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>CutSim</string>
    <key>CFBundleDisplayName</key>        <string>CutSim</string>
    <key>CFBundleExecutable</key>         <string>CutSim</string>
    <key>CFBundleIdentifier</key>         <string>com.jhg.cutsim</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>   <string>NC Program</string>
            <key>CFBundleTypeRole</key>   <string>Viewer</string>
            <key>LSItemContentTypes</key> <array><string>public.plain-text</string></array>
            <key>CFBundleTypeExtensions</key> <array><string>nc</string><string>gcode</string><string>ngc</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# The runtime-compiled shader lives in the binary, but SwiftPM still emits a
# resource bundle; copy it so nothing goes looking for it in vain.
if [ -d ".build/$CONFIG/CutSim_CutSimApp.bundle" ]; then
    cp -R ".build/$CONFIG/CutSim_CutSimApp.bundle" "$APP/Contents/Resources/"
fi

codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
