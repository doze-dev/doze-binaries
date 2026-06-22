#!/usr/bin/env bash
# recipes/ferretdb/build.sh <version> <ref> <triple> <out_dir>
#   version/ref  e.g. 2.7.0 / v2.7.0
#
# FerretDB is a MongoDB-wire proxy written in pure Go. Upstream ships Linux
# binaries only, so we cross-compile every target from source (CGO disabled),
# which gives us macOS too and keeps all four triples uniform.
#
# NOTE: FerretDB v2 talks to a PostgreSQL backend carrying the DocumentDB
# extension — that runtime dependency is handled by doze's ferretdb engine, not
# here. This recipe only produces the `ferretdb` binary.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"   # absolute, so output survives later cd
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/ferretdb"; mkdir -p "$prefix/bin"

case "$triple" in
  x86_64-*linux*)   export GOOS=linux  GOARCH=amd64 ;;
  aarch64-*linux*)  export GOOS=linux  GOARCH=arm64 ;;
  x86_64-*darwin*)  export GOOS=darwin GOARCH=amd64 ;;
  aarch64-*darwin*) export GOOS=darwin GOARCH=arm64 ;;
  *) echo "unknown triple: $triple" >&2; exit 1 ;;
esac
export CGO_ENABLED=0

pkg="github.com/FerretDB/FerretDB/v2/cmd/ferretdb"
work="$(mktemp -d)"; cd "$work"
go mod init dozebuild >/dev/null 2>&1
GOFLAGS=-mod=mod go get "$pkg@$ref"
GOFLAGS=-mod=mod go build -trimpath -o "$prefix/bin/ferretdb" "$pkg"

"$root/scripts/package.sh" "$prefix" "ferretdb-$version-$triple" "$out"
"$root/scripts/smoke.sh" ferretdb "$out/ferretdb-$version-$triple.tar.gz" "$triple"
