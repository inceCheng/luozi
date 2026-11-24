#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
stage="$(mktemp -d "$PWD/build/.stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/落字.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Info.plist "$app/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos26.0" Sources/*.swift -o "$app/Contents/MacOS/PressSpeak"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier local.pressspeak.mac "$app"
codesign --verify --strict "$app"
destination="$PWD/build/落字.app"
legacy="$PWD/build/按声.app"
if [[ ! -e "$destination" && -d "$legacy" ]] && [[ "$(defaults read "$legacy/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "local.pressspeak.mac" ]]; then
  mv "$legacy" "$destination"
fi
if [[ -e "$destination" ]]; then mv "$destination" "$stage/previous.app"; fi
if ! mv "$app" "$destination"; then
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$destination"; fi
  exit 1
fi
echo "$destination"
