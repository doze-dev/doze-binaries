#!/usr/bin/env bash
# recipes/kvrocks/build.sh <version> <ref> <triple> <out_dir>
#   version/ref  e.g. 2.15.0 / v2.15.0
#
# Apache Kvrocks is a RESP-speaking, RocksDB-backed store. It builds RocksDB and
# its dependency stack from source via x.py, so this is the slowest recipe
# (several minutes per target). On Linux we statically link libstdc++/libgcc for
# portability; the rest is bundled.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"   # absolute, so output survives later cd
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/kvrocks"
src="$(mktemp -d)/src"

git clone --depth 1 --branch "$ref" https://github.com/apache/kvrocks.git "$src"
cd "$src"

case "$triple" in
  *linux*)
    sudo apt-get update -y
    sudo apt-get install -y build-essential cmake autoconf automake libtool \
      python3 libssl-dev pkg-config patchelf git
    export CXXFLAGS="-static-libstdc++ -static-libgcc ${CXXFLAGS:-}"
    ;;
  *darwin*)
    # autoconf/automake/libtool are needed to build kvrocks's vendored jemalloc.
    # Keep `brew install` from cascading into unrelated upgrades (see postgres).
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
    brew install cmake openssl@3 automake autoconf libtool || true
    ;;
esac

./x.py build -j"$(getconf _NPROCESSORS_ONLN)"

mkdir -p "$prefix/bin"
cp build/kvrocks "$prefix/bin/"
[ -f build/kvrocks2redis ] && cp build/kvrocks2redis "$prefix/bin/" || true

case "$triple" in
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" "$(brew --prefix)" ;;
esac

"$root/scripts/package.sh" "$prefix" "kvrocks-$version-$triple" "$out"
"$root/scripts/smoke.sh" kvrocks "$out/kvrocks-$version-$triple.tar.gz" "$triple"
