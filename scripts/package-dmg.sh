#!/bin/bash
# Wrap an existing verified app without rebuilding or re-signing it.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo 'Usage: bash scripts/package-dmg.sh /path/Patch.app /path/Patch.dmg' >&2
    exit 1
fi
app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_parent="$(cd "$(dirname "$2")" && pwd)"
output_path="$output_parent/$(basename "$2")"
if [ "$(basename "$app_path")" != Patch.app ] || [ ! -f "$app_path/Contents/Info.plist" ]; then
    echo 'Expected an existing Patch.app bundle.' >&2
    exit 1
fi
if [[ "$output_path" != *.dmg ]] || [ -e "$output_path" ]; then
    echo 'Output must be a new .dmg file; existing files are never overwritten.' >&2
    exit 1
fi
codesign --verify --deep --strict "$app_path"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/patch-dmg.XXXXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$app_path" "$stage_dir/Patch.app"
ln -s /Applications "$stage_dir/Applications"
cp "$(dirname "$0")/../Distribution/INSTALL-preview.txt" "$stage_dir/安装说明.txt"
hdiutil create -srcfolder "$stage_dir" -volname Patch -fs HFS+ -format UDZO "$output_path"
hdiutil verify "$output_path"
printf 'DMG: %s\n' "$output_path"
