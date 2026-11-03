#!/bin/bash
# Build an explicitly ad-hoc signed GitHub preview; never reuse a local trial app.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
release_tag="${1:-v0.1.0-preview.2}"
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$ ]]; then
    echo 'Expected a tag such as v0.1.0-preview.1' >&2
    exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
    echo 'Preview distribution currently supports Apple Silicon builds only.' >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo 'Commit or isolate source changes before packaging a traceable release.' >&2
    exit 1
fi
source_commit="$(git rev-parse HEAD)"
output_dir="$screenleaf_root/dist/$release_tag"
if [ -e "$output_dir" ]; then
    echo "Refusing to overwrite: $output_dir" >&2
    exit 1
fi
mkdir -p "$output_dir"
SCREENLEAF_OUTPUT_DIR="$output_dir" bash scripts/build-app.sh release
app_path="$output_dir/Patch.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Patch' "$app_path/Contents/Info.plist"
codesign --force --sign - --entitlements Distribution/Patch.entitlements "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
archive_name="Patch-${release_tag#v}-macOS-arm64.zip"
# Resource forks, Finder metadata and local extended attributes are not needed.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$output_dir/$archive_name"
dmg_name="${archive_name%.zip}.dmg"
bash scripts/package-dmg.sh "$app_path" "$output_dir/$dmg_name"
cp docs/install.md "$output_dir/INSTALL.md"
python3 - "$output_dir" "$archive_name" "$release_tag" "$source_commit" <<'PY'
import hashlib, json, pathlib, plistlib, sys
out = pathlib.Path(sys.argv[1])
archive, tag, commit = sys.argv[2:]
info = plistlib.loads((out / 'Patch.app/Contents/Info.plist').read_bytes())
if tag.split('-preview.')[0] != 'v' + info['CFBundleShortVersionString']:
    raise SystemExit('Tag and bundle version disagree; do not publish')
archive_hash = hashlib.sha256((out / archive).read_bytes()).hexdigest()
dmg = archive.removesuffix('.zip') + '.dmg'
dmg_hash = hashlib.sha256((out / dmg).read_bytes()).hexdigest()
manifest = {
    'product': 'Patch', 'release_tag': tag, 'channel': 'preview',
    'repository': 'https://github.com/caijyii/patch', 'source_commit': commit,
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'bundle_identifier': info['CFBundleIdentifier'], 'architecture': 'arm64',
    'minimum_macos': info['LSMinimumSystemVersion'],
    'signing': 'ad-hoc', 'notarized': False, 'app_sandbox': True,
    'archive': archive, 'sha256': archive_hash,
    'preferred_installer': dmg,
    'installers': [
        {'file': dmg, 'format': 'dmg', 'sha256': dmg_hash},
        {'file': archive, 'format': 'zip', 'sha256': archive_hash},
    ],
    'download_url': f'https://github.com/caijyii/patch/releases/download/{tag}/{archive}',
}
(out / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
assets = [dmg, archive, 'INSTALL.md', 'release-manifest.json']
(out / 'SHA256SUMS.txt').write_text(''.join(
    f'{hashlib.sha256((out / name).read_bytes()).hexdigest()}  {name}\n' for name in assets))
print(f'Preview assets ready: {out}')
print(f'Archive SHA-256: {archive_hash}')
PY
