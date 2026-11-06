#!/bin/bash
# Compatibility entry point for preview releases.
set -euo pipefail
release_tag="${1:-v0.1.0-preview.6}"
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$ ]]; then
    echo 'Expected a preview tag such as v0.1.0-preview.6' >&2
    exit 1
fi
exec bash "$(dirname "$0")/package-release.sh" "$release_tag"
