#!/bin/zsh
# Builds Swapkey.app into ./build and signs it.
#
# Signs with the self-signed "Punto Dev" certificate if it is in the keychain: the Accessibility
# permission is tied to the signature, and with a stable certificate it survives rebuilds.
# Without it falls back to ad-hoc signing, which changes on every build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Swapkey.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Swapkey"

# A running Swapkey must not outlive its bundle: its event tap would be left with a signature
# that no longer matches the Accessibility grant, and a tap without permission freezes all input.
if pkill -x Swapkey; then
    echo "Stopped running Swapkey"
    while pgrep -x Swapkey >/dev/null; do sleep 0.1; done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Swapkey"
# Regenerate with: swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.swapkey</string>
    <key>CFBundleName</key><string>Swapkey</string>
    <key>CFBundleExecutable</key><string>Swapkey</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

SIGN_NAME="Punto Dev"
# No -v: the self-signed certificate is "not trusted", but codesign can still use it.
IDENTITY="$(security find-identity -p codesigning | awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }')"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --identifier local.swapkey "$APP"
else
    echo "warning: \"$SIGN_NAME\" certificate not found, signing ad-hoc (Accessibility must be re-granted after each build)" >&2
    codesign --force --sign - --identifier local.swapkey "$APP"
fi
echo "Built $APP"
