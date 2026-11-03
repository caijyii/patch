#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/home-scenery"
mkdir -p "$task_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/HomeSeason.swift Sources/ScreenLeaf/HomeSceneryArtwork.swift \
    Sources/ScreenLeaf/HomeScenery.swift scripts/verify-home-scenery.swift -o "$task_work/verify-home-scenery"
"$task_work/verify-home-scenery" | tee "$task_work/results.log"
grep -Fq 'PASS: home scenery initialization, day/clock/timezone/wake refresh and inactive lifecycle' "$task_work/results.log"
