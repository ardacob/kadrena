#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/outputs/Kadrena.app"
cache_dir="$repo_dir/work/module-cache"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$cache_dir"
cp "$repo_dir/macos/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/assets/AppIcon.png" "$app_dir/Contents/Resources/AppIcon.png"
xcrun swiftc -disable-sandbox -parse-as-library -swift-version 5 -O -target arm64-apple-macos13.0 \
  -module-cache-path "$cache_dir" "$repo_dir/macos/Kadrena.swift" \
  -o "$app_dir/Contents/MacOS/Kadrena"
codesign --force --deep --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
