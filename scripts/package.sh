#!/usr/bin/env bash
# package.sh <staging_dir> <archive_basename> <out_dir>
#
# Tars a staged install directory into <out_dir>/<archive_basename>.tar.gz with a
# single top-level directory named <archive_basename>, plus a .sha256 sidecar.
set -euo pipefail

staging="$1"; base="$2"; out="${3:-dist}"
mkdir -p "$out"
work="$(mktemp -d)"
cp -R "$staging" "$work/$base"
# macOS tar otherwise adds an AppleDouble ._<name> entry for every file with
# extended attributes (signatures, provenance): junk on Linux, and a ._x.control
# copied into a Postgres tree would read as an extension.
COPYFILE_DISABLE=1 tar -C "$work" -czf "$out/$base.tar.gz" "$base"
if COPYFILE_DISABLE=1 tar -tzf "$out/$base.tar.gz" | grep -q '/\._\|^\._'; then
  echo "package.sh: $base.tar.gz still holds AppleDouble ._ entries" >&2
  exit 1
fi
# sha256sum where shasum is missing (Git Bash on the Windows runners has coreutils, not always perl's shasum).
sum() { if command -v shasum >/dev/null; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
( cd "$out" && sum "$base.tar.gz" > "$base.tar.gz.sha256" )
rm -rf "$work"
echo "packaged $out/$base.tar.gz"
