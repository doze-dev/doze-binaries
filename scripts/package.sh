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
tar -C "$work" -czf "$out/$base.tar.gz" "$base"
( cd "$out" && shasum -a 256 "$base.tar.gz" > "$base.tar.gz.sha256" )
rm -rf "$work"
echo "packaged $out/$base.tar.gz"
