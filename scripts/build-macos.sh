#!/bin/bash
# Build HTML辑霸.app — Swift native shell + Python backend
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/HTML辑霸/Sources"
APP_NAME="HTML辑霸"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
RES="$APP/Contents/Resources"
MACOS="$APP/Contents/MacOS"

echo "==> Building $APP_NAME"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# --- compile Swift ---
echo "==> swiftc"
xcrun swiftc -O \
  -parse-as-library \
  -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI \
  -framework AppKit \
  -framework WebKit \
  -framework Combine \
  -framework UniformTypeIdentifiers \
  "$SRC"/*.swift \
  -o "$MACOS/$APP_NAME"

echo "==> bundle backend"
cp -R "$ROOT/src/app" "$RES/app"
rm -rf "$RES/app/__pycache__" "$RES/app/.venv" 2>/dev/null || true
cp "$ROOT/requirements.txt" "$RES/"
cp "$ROOT/native/HTML辑霸/Sources/launch_backend.py" "$RES/"
cp "$ROOT/native/HTML辑霸/Sources/server_lite.py" "$RES/app/"
cp "$ROOT/native/HTML辑霸/Sources/server_lite.py" "$RES/"

# --- icon ---
ICON_PNG="$ROOT/assets/AppIcon.png"
if [ -f "$ICON_PNG" ]; then
  echo "==> icon"
  ICONSET="$RES/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
  rm -rf "$ICONSET"
  # also keep png
  cp "$ICON_PNG" "$RES/AppIcon.png"
fi

# --- Info.plist ---
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>local.htmleditor.jiba</string>
  <key>CFBundleVersion</key>
  <string>4.2.0</string>
  <key>CFBundleShortVersionString</key>
  <string>4.2.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# --- ad-hoc sign ---
codesign --force --deep -s - "$APP" 2>/dev/null || true

# install helper command next to dist
cp "$ROOT/scripts/启动HTML辑霸.command" "$DIST/" 2>/dev/null || true
chmod +x "$DIST/启动HTML辑霸.command" 2>/dev/null || true

echo "==> done: $APP"
ls -la "$MACOS"
ls "$RES" | head
