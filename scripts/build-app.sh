#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# No credentials are stored by this script. Pass an existing signing identity
# only when producing a Developer ID build for distribution.
swift build -c release --scratch-path .build/scan-fix
bin_dir=$(swift build -c release --scratch-path .build/scan-fix --show-bin-path)
out="$PWD/.build/Distribution"
app="$out/LintGoblin.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/DiskSense.iconset"
/usr/bin/install -m 755 "$bin_dir/DiskSense" "$app/Contents/MacOS/DiskSense"
swift scripts/MakeIcon.swift "$out/DiskSense.iconset"
/usr/bin/iconutil -c icns "$out/DiskSense.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LintGoblin</string>
<key>CFBundleDisplayName</key><string>LintGoblin</string>
<key>CFBundleIdentifier</key><string>com.sar.disksense</string>
<key>CFBundleExecutable</key><string>DiskSense</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ -n "${DISKSENSE_SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$DISKSENSE_SIGNING_IDENTITY" "$app"
else
  /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$out/LintGoblin-0.5.1.zip"
printf 'Built %s\n' "$app" "$out/LintGoblin-0.5.1.zip"
