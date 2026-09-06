#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/CodexPetStandalone.app"
INSTALL_APP_DIR="$HOME/Applications/Codex Pet.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/dist/PetIcon.iconset"
ICON_SOURCE="${CODEX_PET_ICON_SOURCE:-$HOME/.codex/pets/HootOwl.png}"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/CodexPetStandalone" "$MACOS_DIR/CodexPetStandalone"
chmod +x "$MACOS_DIR/CodexPetStandalone"

if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$RESOURCES_DIR/.env"
fi

if [[ -f "$ICON_SOURCE" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/PetIcon.icns"
  rm -rf "$ICONSET_DIR"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexPetStandalone</string>
  <key>CFBundleIdentifier</key>
  <string>local.hal.codex-pet-standalone</string>
  <key>CFBundleName</key>
  <string>Codex Pet</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>PetIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Codex Pet connects to Hermes Agent on your local DXP-2800 NAS.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Codex Pet uses the microphone when voice mode is on so it can listen to your conversation.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Codex Pet uses speech recognition when voice mode is on so it can show and speak a response.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Codex Pet links Todo items with the macOS Reminders app.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Codex Pet links schedules with the macOS Calendar app.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" >/dev/null

mkdir -p "$(dirname "$INSTALL_APP_DIR")"
rm -rf "$INSTALL_APP_DIR"
ditto "$APP_DIR" "$INSTALL_APP_DIR"

echo "$APP_DIR"
echo "$INSTALL_APP_DIR"
