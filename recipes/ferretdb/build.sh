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

# Build inside the upstream clone so its go.sum pins the dependency graph
# (see scripts/build-go-binary.sh for why fresh resolution is not an option).
"$root/scripts/build-go-binary.sh" https://github.com/FerretDB/FerretDB.git \
  "$ref" "$triple" ./cmd/ferretdb "$prefix/bin/ferretdb"

"$root/scripts/package.sh" "$prefix" "ferretdb-$version-$triple" "$out"
"$root/scripts/smoke.sh" ferretdb "$out/ferretdb-$version-$triple.tar.gz" "$triple"
