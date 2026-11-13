#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
bash "$screenleaf_root/scripts/build-app.sh" release
archive_path="$screenleaf_root/dist/Patch-0.1.5-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent "$screenleaf_root/dist/Patch.app" "$archive_path"
printf 'Archive: %s\n' "$archive_path"
