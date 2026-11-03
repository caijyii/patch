#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/images"

if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
if [[ "$#" -gt 1 ]] || [[ "$#" -eq 1 && "$1" != "--ocr" ]]; then
    printf 'Usage: scripts/verify-images.sh [--ocr]\n' >&2
    exit 2
fi
mkdir -p "$task_work/module-cache"
# Private helpers remain private in production. The probe shares their temporary
# source file only for verification; no capture, pasteboard mutation or permissions.
cat "$task_root/Sources/ScreenLeaf/ImageTools.swift" "$task_root/scripts/verify-images.swift" \
    > "$task_work/ImageToolsVerification.swift"
printf 'Verifying images with SDK: %s\n' "$task_sdk"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target arm64-apple-macosx15.0 \
    "$task_root/Sources/ScreenLeaf/CaptureRegion.swift" \
    "$task_root/Sources/ScreenLeaf/Preferences.swift" "$task_root/Sources/ScreenLeaf/AnnotationControls.swift" \
    "$task_root/Sources/ScreenLeaf/SubjectExtraction.swift" "$task_root/Sources/ScreenLeaf/SubjectSelection.swift" \
    "$task_work/ImageToolsVerification.swift" \
    -o "$task_work/verify-images"
"$task_work/verify-images" "$task_work" "$@"
