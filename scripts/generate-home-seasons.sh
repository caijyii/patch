#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/seasonal-themes-20261022"
task_output="${1:-$screenleaf_root/design/home-seasons}"
mkdir -p "$task_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/HomeSeason.swift Sources/Patch/HomeSceneryArtwork.swift \
    scripts/generate-home-seasons.swift -o "$task_work/generate-home-seasons"
"$task_work/generate-home-seasons" "$task_output"
