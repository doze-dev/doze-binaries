#!/usr/bin/env bash
# recipes/valkey/build.sh <version> <ref> <triple> <out_dir>
#   version/ref  e.g. 9.1.0 / 9.1.0   (valkey tags carry no leading "v")
#
# Valkey publishes no prebuilt binaries, so we build from source. It vendors and
# statically links jemalloc, so the result is nearly self-contained.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"   # absolute, so output survives later cd
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/valkey"
src="$(mktemp -d)/src"

git clone --depth 1 --branch "$ref" https://github.com/valkey-io/valkey.git "$src"
cd "$src"

case "$triple" in
  *linux*) sudo apt-get update -y && sudo apt-get install -y build-essential pkg-config patchelf ;;
esac

make -j"$(getconf _NPROCESSORS_ONLN)"
make PREFIX="$prefix" install

case "$triple" in
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" "$(brew --prefix)" ;;
esac

"$root/scripts/package.sh" "$prefix" "valkey-$version-$triple" "$out"
"$root/scripts/smoke.sh" valkey "$out/valkey-$version-$triple.tar.gz" "$triple"
