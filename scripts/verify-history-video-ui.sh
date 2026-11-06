#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
video_ui_work="$screenleaf_root/.build/verification/history-video-ui"
mkdir -p "$video_ui_work"
video_ui_sources=()
for video_ui_source in Sources/Patch/*.swift; do
    if [[ "$video_ui_source" != Sources/Patch/App.swift ]]; then video_ui_sources+=("$video_ui_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${video_ui_sources[@]}" scripts/verify-history-video-ui.swift -o "$video_ui_work/verify-history-video-ui"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: history video UI verification (not launched)\n'
    exit 0
fi
if [[ "$#" != 1 || ! -f "$1" ]]; then
    printf 'Usage: bash scripts/verify-history-video-ui.sh <synthetic-video-fixture>\n' >&2
    exit 64
fi
"$video_ui_work/verify-history-video-ui" "$video_ui_work" "$1" | tee "$video_ui_work/results.log"
if ! rg -Fqx 'PASS: history video UI verification completed' "$video_ui_work/results.log"; then
    printf 'History video UI verification did not complete.\n' >&2
    exit 1
fi
