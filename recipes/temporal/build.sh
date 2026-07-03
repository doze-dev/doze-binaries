#!/usr/bin/env bash
# recipes/temporal/build.sh <version> <ref> <triple> <out_dir>
#   version/ref  e.g. 1.1.0 / v1.1.0
#
# The Temporal CLI (temporalio/cli) is a single pure-Go binary whose `server
# start-dev` subcommand bundles the Temporal server + SQLite persistence + Web UI.
# We cross-compile it from source (CGO disabled) for every triple, mirroring the
# ferretdb recipe — uniform, and it sidesteps upstream release-asset naming.
#
# NOTE: start-dev's SQLite store uses modernc.org/sqlite (pure Go), so CGO stays
# disabled and the resulting binary is self-contained (no bundled libs needed).
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/temporal"; mkdir -p "$prefix/bin"

case "$triple" in
  x86_64-*linux*)   export GOOS=linux  GOARCH=amd64 ;;
  aarch64-*linux*)  export GOOS=linux  GOARCH=arm64 ;;
  x86_64-*darwin*)  export GOOS=darwin GOARCH=amd64 ;;
  aarch64-*darwin*) export GOOS=darwin GOARCH=arm64 ;;
  *) echo "unknown triple: $triple" >&2; exit 1 ;;
esac
export CGO_ENABLED=0

pkg="github.com/temporalio/cli/cmd/temporal"
work="$(mktemp -d)"; cd "$work"
go mod init dozebuild >/dev/null 2>&1
GOFLAGS=-mod=mod go get "$pkg@$ref"
GOFLAGS=-mod=mod go build -trimpath -o "$prefix/bin/temporal" "$pkg"

"$root/scripts/package.sh" "$prefix" "temporal-$version-$triple" "$out"
"$root/scripts/smoke.sh" temporal "$out/temporal-$version-$triple.tar.gz" "$triple"
