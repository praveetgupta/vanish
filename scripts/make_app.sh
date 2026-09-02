#!/bin/bash
# Build Vanish.app: sets up the Python engine's venv, compiles the Swift app,
# wraps it in a proper bundle, embeds the engine, and ad-hoc signs it.
#
#   scripts/make_app.sh              build into ./Vanish.app
#   scripts/make_app.sh --install    also copy it to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Vanish.app"
VENV="$ROOT/engine/venv"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

# --- 1. Python engine ------------------------------------------------------
if [[ ! -x "$VENV/bin/python" ]]; then
  PY="$(command -v python3.14 || command -v python3.13 || command -v python3.12 || command -v python3 || true)"
  [[ -n "$PY" ]] || { echo "error: no python3 found. Install it with: brew install python@3.13"; exit 1; }
  echo "==> creating engine venv with $PY"
  "$PY" -m venv "$VENV"
fi

echo "==> installing engine dependencies"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r "$ROOT/engine/requirements.txt"

# --- 2. Swift app ----------------------------------------------------------
command -v swift >/dev/null || { echo "error: swift not found. Install Xcode or the Command Line Tools."; exit 1; }
echo "==> swift build (release)"
cd "$ROOT/app"
swift build -c release

# --- 3. Bundle -------------------------------------------------------------
echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/Vanish" "$APP/Contents/MacOS/Vanish"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vanish</string>
    <key>CFBundleDisplayName</key><string>Vanish</string>
    <key>CFBundleIdentifier</key><string>local.vanish.app</string>
    <key>CFBundleExecutable</key><string>Vanish</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> embedding engine"
# The venv's python is a symlink into the system/Homebrew install; cp -R keeps
# it a symlink, so the bundle stays small and follows your Python upgrades.
rm -rf "$APP/Contents/Resources/engine"
cp -R "$ROOT/engine" "$APP/Contents/Resources/engine"
find "$APP/Contents/Resources/engine" -name __pycache__ -type d -prune -exec rm -rf {} +

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || codesign --force --sign - "$APP"

if [[ $INSTALL == 1 ]]; then
  echo "==> installing to /Applications"
  osascript -e 'quit app "Vanish"' 2>/dev/null || true
  rm -rf /Applications/Vanish.app
  cp -R "$APP" /Applications/Vanish.app
  echo "Installed: /Applications/Vanish.app"
fi

echo "Built: $APP"
