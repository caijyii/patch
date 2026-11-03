#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"

reopen_work="$screenleaf_root/.build/verification/reopen"
mkdir -p "$reopen_work"
reopen_cache="$reopen_work/module-cache"
mkdir -p "$reopen_cache"
export CLANG_MODULE_CACHE_PATH="$reopen_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$reopen_cache"
# Test the real delegate without launching the production @main entry point.
python3 - "$screenleaf_root/Sources/ScreenLeaf/App.swift" "$reopen_work/AppUnderTest.swift" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
marker = '@MainActor\nfinal class AppDelegate'
Path(sys.argv[2]).write_text('import AppKit\nimport Carbon\nimport Darwin\n\n' + source[source.index(marker):] + '''
extension AppDelegate {
    var verificationMenuTitles: [String] { statusItem.menu?.items.map(\\.title) ?? [] }
    var verificationStatusMenu: NSMenu { statusItem.menu! }
    var verificationImageTools: ImageToolsCoordinator { imageTools }
}
''')
PY

reopen_inputs=()
for reopen_source in "$screenleaf_root"/Sources/ScreenLeaf/*.swift; do
    if [[ "$reopen_source" != "$screenleaf_root/Sources/ScreenLeaf/App.swift" ]]; then
        reopen_inputs+=("$reopen_source")
    fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$reopen_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${reopen_inputs[@]}" "$reopen_work/AppUnderTest.swift" \
    "$screenleaf_root/scripts/verify-reopen.swift" -o "$reopen_work/probe"
"$reopen_work/probe" "$reopen_work" | tee "$reopen_work/results.log"
# AppKit can exit before main completes when native services are unavailable.
# A zero exit status alone must never turn that into a successful UI check.
if ! grep -Fxq 'PASS: 13 Home/reopen groups; 0 failures' "$reopen_work/results.log"; then
    echo "Home verification did not complete; run with access to native AppKit services." >&2
    exit 1
fi
