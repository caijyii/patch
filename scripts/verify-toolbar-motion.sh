#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/toolbar-motion"
mkdir -p "$task_work/module-cache"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--build-only" ) ]]; then
    printf 'Usage: scripts/verify-toolbar-motion.sh [--build-only]\n' >&2
    exit 2
fi
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/Localization.swift Sources/Patch/Preferences.swift Sources/Patch/AnnotationControls.swift \
    scripts/verify-toolbar-motion.swift -o "$task_work/verify-toolbar-motion"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: toolbar verification (not launched)\n'
    exit 0
fi
"$task_work/verify-toolbar-motion" "$task_work" | tee "$task_work/results.log"
# Native AppKit may exit early without a nonzero process status in a sandbox.
if ! grep -Fxq 'COMPLETE: toolbar motion verification: 17 PASS, 0 FAIL' "$task_work/results.log"; then
    echo "Toolbar verification did not complete; native AppKit services are required." >&2
    exit 1
fi
