#!/usr/bin/env bash
# build-go-binary.sh <repo_url> <ref> <triple> <pkg> <out_bin> [ldflags]
#
# Shared build arm for the pure-Go engines (ferretdb, temporal): clone the tag
# and build INSIDE the upstream repo, so its own go.mod/go.sum pin the entire
# dependency graph exactly as upstream released it. The previous approach
# (`go mod init && go get pkg@ref` in an empty module) re-resolved dependencies
# fresh, which silently drifts from upstream's lockfile and broke older tags
# outright — temporal CLI 1.0.0's freshly-resolved graph no longer compiles.
#
# ldflags, when given, is passed through — for upstreams that stamp their
# version with -X in release builds (temporal), which an in-repo build of a
# tag otherwise reports as a dev version.
set -euo pipefail

repo="$1"; ref="$2"; triple="$3"; pkg="$4"; out_bin="$5"; ldflags="${6:-}"

case "$triple" in
  x86_64-*linux*)   export GOOS=linux  GOARCH=amd64 ;;
  aarch64-*linux*)  export GOOS=linux  GOARCH=arm64 ;;
  x86_64-*darwin*)  export GOOS=darwin GOARCH=amd64 ;;
  aarch64-*darwin*) export GOOS=darwin GOARCH=arm64 ;;
  *) echo "unknown triple: $triple" >&2; exit 1 ;;
esac
export CGO_ENABLED=0

src="$(mktemp -d)/src"
# Skip LFS smudge: FerretDB stores website/blog images in git-lfs, and
# upstream's LFS budget being exhausted fails the whole checkout over assets a
# `go build` never touches. Pointer files land instead of blobs, which is fine.
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$ref" "$repo" "$src"
cd "$src"
# -mod=readonly (the default) enforces the repo's go.mod/go.sum as-is.
if [ -n "$ldflags" ]; then
  go build -trimpath -ldflags "$ldflags" -o "$out_bin" "$pkg"
else
  go build -trimpath -o "$out_bin" "$pkg"
fi
