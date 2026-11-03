#!/usr/bin/env python3
"""Export a reviewable source snapshot, never build outputs or local credentials."""
from pathlib import Path
import argparse
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FILES = ("README.md", "LICENSE", "BRANDING.md", "THIRD_PARTY_NOTICES.md",
         "CONTRIBUTING.md", "SECURITY.md", "Package.swift", ".gitignore", ".gitattributes")
DIRECTORIES = ("Sources", "Resources", "Tests", "scripts", "design", "docs", "Distribution", ".github")
SENSITIVE_SUFFIXES = {".p12", ".p8", ".key", ".pem", ".mobileprovision", ".provisionprofile", ".xcuserstate"}


def source_files():
    paths = [ROOT / name for name in FILES]
    for name in DIRECTORIES:
        paths.extend(p for p in (ROOT / name).rglob("*") if p.is_file() or p.is_symlink())
    result = []
    for path in sorted(set(paths)):
        relative = path.relative_to(ROOT)
        if any(part in {"__pycache__", ".DS_Store"} for part in relative.parts):
            continue
        if path.is_symlink() or path.suffix.lower() in SENSITIVE_SUFFIXES or path.name.startswith(".env"):
            raise SystemExit(f"Refusing potentially private file or symlink: {relative}")
        if not path.is_file():
            raise SystemExit(f"Missing required source file: {relative}")
        result.append((path, relative))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new ZIP path; existing files are never overwritten")
    args = parser.parse_args()
    files = source_files()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents and output.relative_to(ROOT).parts[0] not in {".build", "dist"}:
        raise SystemExit("Use .build/, dist/, or a directory outside the source tree for the archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, relative in files:
            archive.write(path, Path("Patch-source") / relative)
    print(f"Source snapshot: {output} ({len(files)} files, {output.stat().st_size} bytes)")
    print("Review content and licensing before public release; this is not a credential scanner.")


if __name__ == "__main__":
    main()
