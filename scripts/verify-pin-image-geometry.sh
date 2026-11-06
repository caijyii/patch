#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
output="$screenleaf_root/.build/verification/pin-image-geometry"
mkdir -p "$output/module-cache"
python3 - "$screenleaf_root" "$output/Verification.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "Sources/ScreenLeaf/ImageTools.swift").read_text()
geometry = source.split("// PIN_IMAGE_GEOMETRY_BEGIN\n", 1)[1].split("// PIN_IMAGE_GEOMETRY_END", 1)[0]
probe = (root / "scripts/verify-pin-image-geometry.swift").read_text()
Path(sys.argv[2]).write_text("import AppKit\n" + geometry + "\n" + probe)
PY
xcrun swiftc -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$output/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    "$output/Verification.swift" -o "$output/verify-pin-image-geometry"
"$output/verify-pin-image-geometry" --verify
