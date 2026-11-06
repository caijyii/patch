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
source "$(dirname "$0")/environment.sh"
dmg_python="$screenleaf_root/.build/dmg-tools/bin/python"
if [[ ! -x "$dmg_python" ]] || ! "$dmg_python" -c 'import dmgbuild, ds_store, mac_alias' >/dev/null 2>&1; then
    echo 'Run bash scripts/setup-dmg-tools.sh once to install the isolated DMG build tools.' >&2
    exit 1
fi
art_dir="$(mktemp -d "$screenleaf_root/.build/dmg-art.XXXXXXXX")"
trap 'rm -rf "$art_dir"' EXIT
xcrun swiftc -module-cache-path "$screenleaf_cache" "$screenleaf_root/scripts/generate-dmg-artwork.swift" -o "$art_dir/generate"
"$art_dir/generate" "$art_dir/background@2x.png"
"$dmg_python" -m dmgbuild -s "$screenleaf_root/Distribution/DMG/settings.py" \
    -D "app=$app_path" \
    -D "background=$art_dir/background@2x.png" \
    Patch "$output_path"
hdiutil verify "$output_path"
printf 'DMG: %s\n' "$output_path"
