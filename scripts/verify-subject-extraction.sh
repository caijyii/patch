#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/subject-extraction"

if [[ "$#" -ne 1 ]]; then
    printf 'Usage: scripts/verify-subject-extraction.sh DUCK_SAMPLE_IMAGE\n' >&2
    exit 2
fi
if [[ ! -f "$1" ]]; then
    printf 'FAIL: sample image does not exist: %s\n' "$1" >&2
    exit 1
fi
if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
mkdir -p "$task_work/module-cache"
printf 'Verifying subject extraction with SDK: %s\n' "$task_sdk"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    "$task_root/Sources/Patch/SubjectExtraction.swift" \
    "$task_root/scripts/verify-subject-extraction.swift" -o "$task_work/verify-subject-extraction"
"$task_work/verify-subject-extraction" "$1" "$task_work"
