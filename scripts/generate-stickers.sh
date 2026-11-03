#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
sticker_generator_dir="$screenleaf_root/.build/sticker-generator"
mkdir -p "$sticker_generator_dir"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    scripts/generate-stickers.swift -o "$sticker_generator_dir/generate-stickers"
"$sticker_generator_dir/generate-stickers" "$screenleaf_root"
