#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="IINA Companion Menu"
APP_DIR="$ROOT/release/$APP_NAME.app"

if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"

cd "$ROOT"
swift build --disable-sandbox -c debug
BUILD_DIR="$(swift build --disable-sandbox -c debug --show-bin-path)"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/IINACompanionMenu" "$APP_DIR/Contents/MacOS/IINACompanionMenu"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

cp "$ROOT/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR"

ARCHIVE="$ROOT/release/IINA-Companion-Menu-0.4.2.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
echo "$APP_DIR"
