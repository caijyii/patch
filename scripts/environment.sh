#!/bin/bash
# Shared build settings; keep all compiler and package caches inside the project.
screenleaf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${SCREENLEAF_SDK:-}" ]; then
    screenleaf_sdk="$SCREENLEAF_SDK"
else
    screenleaf_sdk="$(xcrun --show-sdk-path)"
fi
screenleaf_cache="$screenleaf_root/.build/module-cache"
mkdir -p "$screenleaf_cache"
export CLANG_MODULE_CACHE_PATH="$screenleaf_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$screenleaf_cache"
screenleaf_build_arguments=(--sdk "$screenleaf_sdk" --cache-path "$screenleaf_root/.build/package-cache"
    --config-path "$screenleaf_root/.build/package-config"
    -Xswiftc -module-cache-path -Xswiftc "$screenleaf_cache"
    -Xcc "-fmodules-cache-path=$screenleaf_cache")
