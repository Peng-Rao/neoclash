#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NeoClash"
BUNDLE_ID="com.pengrao.NeoClash"
RESOURCE_BUNDLE_NAME="NeoClash_NeoClashApp.bundle"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_existing_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  swift build --product "$APP_NAME"

  local build_dir
  build_dir="$(swift build --show-bin-path)"
  local build_binary="$build_dir/$APP_NAME"
  local build_resource_bundle="$build_dir/$RESOURCE_BUNDLE_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  if [[ -d "$build_resource_bundle" ]]; then
    cp -R "$build_resource_bundle" "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
  fi

  compile_app_icon

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

# The SwiftPM resource bundle carries the raw asset catalog but nothing compiles it, so the
# .app would ship without a Dock/Finder icon. Compile AppIcon.icns the way Xcode does; the
# release workflow builds with xcodebuild and does not need this.
compile_app_icon() {
  local assets_dir="$ROOT_DIR/NeoClash/Resources/Assets.xcassets"
  local icon_out
  icon_out="$(mktemp -d)"
  if xcrun actool "$assets_dir" \
      --compile "$icon_out" \
      --platform macosx \
      --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
      --app-icon AppIcon \
      --output-partial-info-plist "$icon_out/partial.plist" >/dev/null 2>&1 \
      && [[ -f "$icon_out/AppIcon.icns" ]]; then
    mkdir -p "$APP_CONTENTS/Resources"
    cp "$icon_out/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
  else
    echo "warning: could not compile AppIcon.icns; the app will use the generic icon" >&2
  fi
  rm -rf "$icon_out"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_existing_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
