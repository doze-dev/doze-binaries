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
    # kvrocks ≤2.13 forwards "-isysroot ${CMAKE_OSX_SYSROOT}" into its lz4/zstd
    # sub-makes. CMake 4.x no longer sets CMAKE_OSX_SYSROOT by default, so the
    # flag expanded empty and -isysroot swallowed the next arg ("no such sysroot
    # directory", then missing stdlib.h). SDKROOT re-seeds it on any CMake.
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    ;;
esac

# Older kvrocks (≤2.2-era) vendors a googletest whose cmake_minimum_required
# predates 3.5, which CMake 4.x (Homebrew on the macOS runners) refuses to
# configure. This env var relaxes that floor; CMake <4 ignores it entirely.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

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
