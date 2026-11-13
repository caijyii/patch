#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/recent-content"
case "${1:-}" in
    "") task_pass='PASS: recent content, clipboard lifecycle, preference migration and appearance verification completed' ;;
    --rich-text) task_pass='PASS: rich history, retention and clipboard regression suite' ;;
    --text-actions) task_pass='PASS: text history actions verification completed' ;;
    --build-only) task_pass='' ;;
    *) printf 'Usage: scripts/verify-recent-content.sh [--build-only|--rich-text|--text-actions]\n' >&2; exit 64 ;;
esac
mkdir -p "$task_work"
task_sources=()
for task_source in Sources/Patch/*.swift; do
    if [[ "$task_source" != Sources/Patch/App.swift ]]; then task_sources+=("$task_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_sources[@]}" scripts/verify-recent-content.swift -o "$task_work/verify-recent-content"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: recent content verification (not launched)\n'
    exit 0
fi
"$task_work/verify-recent-content" "$task_work" ${1:+"$1"} | tee "$task_work/results.log"

if ! rg -Fqx "$task_pass" "$task_work/results.log"; then
    printf 'FAIL: recent content verification did not complete\n' >&2
    exit 1
fi
