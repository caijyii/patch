#!/bin/bash
# Local development validation only; this is not an App Store distribution build.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
output_dir="$screenleaf_root/.build/distribution-check"
SCREENLEAF_OUTPUT_DIR="$output_dir" bash "$screenleaf_root/scripts/build-app.sh" release
app_path="$output_dir/Patch.app"
# Keep development consent/preferences separate from installed and historical trial apps.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.screenleaf.development' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Patch Development' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Patch Development' "$app_path/Contents/Info.plist"
codesign --force --sign - --entitlements "$screenleaf_root/Distribution/Patch.entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
printf 'Local sandbox build (not launched): %s\n' "$app_path"
