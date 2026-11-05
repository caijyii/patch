#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
configuration="${1:-release}"
binary_dir="$screenleaf_root/.build/$configuration"
mkdir -p "$binary_dir"
optimization=(-O)
if [ "$configuration" = debug ]; then optimization=(-Onone -g); fi
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${optimization[@]}" -module-name ScreenLeaf \
    "$screenleaf_root"/Sources/ScreenLeaf/*.swift -o "$binary_dir/Patch"
icon_dir="$screenleaf_root/.build/icons"
mkdir -p "$icon_dir"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/IconArtwork.swift scripts/generate-icons.swift -o "$icon_dir/generate-icons"
"$icon_dir/generate-icons" "$icon_dir"
iconutil -c icns "$icon_dir/AppIcon.iconset" -o "$icon_dir/AppIcon.icns"
output_dir="${SCREENLEAF_OUTPUT_DIR:-$screenleaf_root/dist}"
mkdir -p "$output_dir"
app_path="$output_dir/Patch.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Patch" "$app_path/Contents/MacOS/Patch"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/PrivacyInfo.xcprivacy "$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
cp Resources/ArtworkNotices.json "$app_path/Contents/Resources/ArtworkNotices.json"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app_path/Contents/Resources/"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
cp "$icon_dir/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
# Preserve original vector stickers and their source record for offline rendering.
mkdir -p "$app_path/Contents/Resources/PatchStickers"
cp -R Resources/PatchStickers/. "$app_path/Contents/Resources/PatchStickers/"
cp "$icon_dir/IconPreview.png" "$output_dir/Patch-IconPreview.png"
codesign --force --sign - "$app_path"
printf 'App: %s\n' "$app_path"
