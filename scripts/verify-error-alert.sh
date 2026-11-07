#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
alert_work="$screenleaf_root/.build/verification/error-alert"
mkdir -p "$alert_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/Patch/Localization.swift Sources/Patch/WindowActivation.swift \
    Sources/Patch/CaptureRegion.swift scripts/verify-error-alert.swift -o "$alert_work/probe"
"$alert_work/probe"
