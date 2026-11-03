#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/recording-inspect"
task_arch="$(uname -m)"
case "$task_arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported Mac architecture: $task_arch" >&2; exit 1 ;;
esac
if [ ! -d "$task_sdk" ]; then
    echo "SDK not found: $task_sdk; set SCREENLEAF_VERIFY_SDK to a compatible SDK." >&2
    exit 1
fi
mkdir -p "$task_work/module-cache"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$task_arch-apple-macosx15.0" \
    "$task_root/scripts/inspect-recording.swift" -o "$task_work/inspect-recording"
"$task_work/inspect-recording" "$@"
