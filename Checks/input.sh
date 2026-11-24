#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
stage="$(mktemp -d "$PWD/build/.input.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/Fixture.app/Contents"
mkdir -p "$contents/MacOS"
plutil -create xml1 "$contents/Info.plist"
for entry in "CFBundleIdentifier local.pressspeak.check" "CFBundleExecutable InputCheck" "CFBundleName PressSpeakCheck" "CFBundlePackageType APPL"; do
    plutil -insert "${entry%% *}" -string "${entry#* }" "$contents/Info.plist"
done
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/System.swift Sources/Shortcuts.swift Sources/StopKey.swift Sources/Audio.swift Sources/Cloud.swift Sources/Views.swift Checks/InputCheck.swift -o "$contents/MacOS/InputCheck"
"$contents/MacOS/InputCheck"
