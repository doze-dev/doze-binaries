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

# Build inside the upstream clone so its go.sum pins the dependency graph
# (see scripts/build-go-binary.sh for why fresh resolution is not an option).
# The -X stamp mirrors upstream's release builds; without it an in-repo tag
# build reports "0.0.0-DEV".
"$root/scripts/build-go-binary.sh" https://github.com/temporalio/cli.git \
  "$ref" "$triple" ./cmd/temporal "$prefix/bin/temporal" \
  "-X github.com/temporalio/cli/temporalcli.Version=$version"

"$root/scripts/package.sh" "$prefix" "temporal-$version-$triple" "$out"
"$root/scripts/smoke.sh" temporal "$out/temporal-$version-$triple.tar.gz" "$triple"
