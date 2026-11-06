#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
mkdir -p .build/verification
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/ScrollEventRouting.swift scripts/verify-scroll-hit-test.swift \
    -o .build/verification/scroll-hit-test
.build/verification/scroll-hit-test
