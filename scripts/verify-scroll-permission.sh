#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
mkdir -p .build/verification
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/ScrollCapturePermission.swift Sources/ScreenLeaf/WindowActivation.swift Sources/ScreenLeaf/Localization.swift scripts/verify-scroll-permission.swift \
    -o .build/verification/scroll-permission
.build/verification/scroll-permission
