#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/preferences"
if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "${1:-}" != "--model-only" ) ]]; then
    printf 'Usage: scripts/verify-preferences.sh [--model-only]\n' >&2
    exit 2
fi
mkdir -p "$task_work/module-cache"
# MemoryPreferencesStorage and FakeHotKeyBackend are injected throughout this probe.
# It does not read UserDefaults, install Carbon handlers, register hotkeys, or post input.
printf 'Verifying preferences and fake hotkeys with SDK: %s\n' "$task_sdk"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    "$task_root/Sources/Patch/Localization.swift" "$task_root/Sources/Patch/WindowTitle.swift" "$task_root/Sources/Patch/Preferences.swift" \
    "$task_root/Sources/Patch/HotKeys.swift" \
    "$task_root/Sources/Patch/Settings.swift" \
    "$task_root/scripts/verify-preferences.swift" -o "$task_work/verify-preferences"
"$task_work/verify-preferences" "$task_work" "$@"
