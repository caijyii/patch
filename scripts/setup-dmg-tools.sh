#!/bin/bash
# Build-only dependencies; never bundled with Patch or installed globally.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
if [[ ! -x "$screenleaf_root/.build/dmg-tools/bin/python" ]]; then
    python3 -m venv "$screenleaf_root/.build/dmg-tools"
fi
"$screenleaf_root/.build/dmg-tools/bin/python" -m pip install --disable-pip-version-check --no-cache-dir -r "$screenleaf_root/Distribution/DMG/requirements.txt"
