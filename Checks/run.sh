#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
stage="$(mktemp -d "$PWD/build/.check.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos26.0" Sources/Audio.swift Sources/Cloud.swift Checks/EngineCheck.swift -o "$stage/check"
if [[ "${1:-}" == "--live" ]]; then
    say -v Tingting -r 240 -o "$stage/sample.aiff" '嗯，把组会改到周三，不对，改到周四下午三点。'
    security find-generic-password -s local.pressspeak.aliyun -a beijing -w | "$stage/check" "$stage/sample.aiff" --live
    exit
fi
say -v Tingting -r 190 -o "$stage/sample.aiff" '请把明天下午的组会改到四点，记得提前十分钟提醒我。'
"$stage/check" "$stage/sample.aiff"
