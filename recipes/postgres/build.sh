#!/usr/bin/env bash
# recipes/postgres/build.sh <version> <ref> <triple> <out_dir>
#   version  e.g. 16.9.0   (three-part for doze compatibility)
#   ref      e.g. REL_16_9 (upstream git branch)
#
# Builds PostgreSQL from source with a featureful-but-lean profile (ICU, OpenSSL,
# LZ4/ZSTD, libxml, readline; no LLVM/Python/LDAP/GSS) and bundles its non-system
# libraries so the tree is relocatable.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"   # absolute, so output survives later cd
root="$(cd "$(dirname "$0")/../.." && pwd)"
major="${version%%.*}"
prefix="$(mktemp -d)/pgsql"
src="$(mktemp -d)/src"

git clone --depth 1 --branch "$ref" -c advice.detachedHead=false \
  https://git.postgresql.org/git/postgresql.git "$src"
cd "$src"

case "$triple" in
  *linux*)
    sudo apt-get update -y
    sudo apt-get install -y build-essential bison flex pkg-config patchelf \
      libreadline-dev zlib1g-dev libicu-dev libssl-dev liblz4-dev libzstd-dev \
      libxml2-dev uuid-dev
    ;;
  *darwin*)
    # Don't let `brew install` drag in upgrades of unrelated installed formulae
    # (that turns a dev-machine build into an hours-long cascade; on clean CI it
    # is simply faster). We only need these specific kegs present.
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
    # pkg-config is how configure locates ICU (icu-uc/icu-i18n). It's preinstalled
    # on CI's macOS runners but not necessarily on a dev machine — install it so a
    # local build finds ICU instead of failing `--with-icu`.
    brew install pkg-config icu4c openssl@3 lz4 zstd libxml2 readline || true
    bp="$(brew --prefix)"
    export PKG_CONFIG_PATH="$bp/opt/icu4c/lib/pkgconfig:$bp/opt/openssl@3/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CPPFLAGS="-I$bp/opt/icu4c/include -I$bp/opt/openssl@3/include -I$bp/opt/readline/include ${CPPFLAGS:-}"
    export LDFLAGS="-L$bp/opt/icu4c/lib -L$bp/opt/openssl@3/lib -L$bp/opt/readline/lib ${LDFLAGS:-}"
    ;;
esac

thread_safety=""
[ "$major" -le 16 ] && thread_safety="--enable-thread-safety"

./configure \
  --prefix="$prefix" \
  --enable-option-checking=fatal \
  --with-icu --with-openssl --with-libxml \
  $([ "$major" -ge 14 ] && echo --with-lz4) \
  $([ "$major" -ge 16 ] && echo --with-zstd) \
  --with-uuid=e2fs --with-readline \
  --with-system-tzdata=/usr/share/zoneinfo \
  --without-ldap $thread_safety

jobs="$(getconf _NPROCESSORS_ONLN)"
if [ "$major" -ge 15 ]; then
  make -j"$jobs" world-bin
  make install-world-bin
else
  make -j"$jobs"
  make install
  make -C contrib install
fi

case "$triple" in
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" "$(brew --prefix)" ;;
esac

"$root/scripts/package.sh" "$prefix" "postgresql-$version-$triple" "$out"
"$root/scripts/smoke.sh" postgres "$out/postgresql-$version-$triple.tar.gz" "$triple"
