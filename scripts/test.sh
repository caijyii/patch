#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
mkdir -p .build/verification
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/WindowActivation.swift Sources/Patch/Localization.swift Sources/Patch/ScrollStitcher.swift \
    Sources/Patch/ScrollEventRouting.swift \
    scripts/verify-core.swift -o .build/verification/core-tests
.build/verification/core-tests "$screenleaf_root/scripts/fixtures"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/RecordingFileStorage.swift scripts/verify-recording-files.swift \
    -o .build/verification/recording-file-tests
.build/verification/recording-file-tests
bash scripts/verify-scroll-permission.sh
