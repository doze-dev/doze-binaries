#!/usr/bin/env bash
# recipes/mariadb/build.sh <version> <ref> <triple> <out_dir>
#   version   e.g. 11.4.5
#   ref       e.g. mariadb-11.4.5   (the upstream release directory name)
#
# Two arms, one curated layout:
#
# - x86_64 Linux REPACKAGES upstream's generic binary tarball (the only triple
#   MariaDB publishes one for): extract the binaries doze needs plus their
#   share/ + plugins, relocate, package, smoke. Published artifacts are
#   immutable, so this arm must stay byte-stable.
# - Every other triple BUILDS FROM SOURCE (the postgres approach): upstream's
#   source tarball (submodules vendored), a lean server profile (no wsrep, no
#   columnstore/rocksdb/mroonga/spider — heavy engines with no doze use case),
#   installed with the standalone layout and then curated through the exact
#   same selection as the repackage arm, so every triple ships an identical
#   tree: bin/{mariadbd,mariadb,mariadb-admin,mariadb-install-db,…}, share/,
#   lib/plugin.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/mariadb"; mkdir -p "$prefix/bin" "$prefix/share" "$prefix/lib"

# curate <tree>: copy the pieces doze actually runs from an upstream tree
# (extracted tarball or an install prefix) into $prefix. Shared by both arms so
# the shipped layout can't diverge between repackaged and source-built triples.
curate() {
  local src="$1" b
  # The binaries doze actually launches (server + client + admin + system-table
  # initializer). Newer MariaDB names them mariadb*; older ship mysql* aliases.
  for b in mariadbd mariadb mariadb-admin mariadb-install-db; do
    if [ -x "$src/bin/$b" ]; then
      cp -p "$src/bin/$b" "$prefix/bin/$b"
    elif [ -x "$src/sbin/$b" ]; then
      cp -p "$src/sbin/$b" "$prefix/bin/$b"
    elif [ -x "$src/scripts/$b" ]; then
      # mariadb-install-db is a shell script shipped under scripts/; it takes
      # --basedir so it relocates fine.
      cp -p "$src/scripts/$b" "$prefix/bin/$b"
    else
      echo "warning: $b not found in upstream tree" >&2
    fi
  done

  # Runtime support data: mariadbd loads error messages + charsets by relative
  # path, and mariadb-install-db bootstraps the system tables from the SQL
  # files in share/ (mysql_system_tables.sql and friends). Ship the whole
  # share/ tree — it is plain data, relocation-safe, and cherry-picking it is
  # how the first release attempt broke.
  cp -R "$src/share/." "$prefix/share/" 2>/dev/null || true

  # Helper tools mariadb-install-db shells out to.
  for b in my_print_defaults resolveip; do
    if [ -x "$src/bin/$b" ]; then cp -p "$src/bin/$b" "$prefix/bin/$b"
    elif [ -x "$src/extra/$b" ]; then cp -p "$src/extra/$b" "$prefix/bin/$b"; fi
  done
  [ -d "$src/lib/plugin" ] && cp -R "$src/lib/plugin" "$prefix/lib/" || true

  # Drop optional plugins that link system libraries doze never ships — they
  # trip the relocation gate and serve no doze use case: OQGraph (libJudy),
  # cracklib password strength (libcrack).
  rm -f "$prefix/lib/plugin/ha_oqgraph.so" "$prefix/lib/plugin/cracklib_password_check.so"
}

case "$triple" in
  x86_64-*linux*)
    # ── Repackage arm: the one triple upstream publishes a generic bintar for.
    sudo apt-get update -y
    # patchelf: the bundle step hard-requires it (and now fails loudly).
    # libncurses5/libtinfo5: the older 11.4.x generic tarballs' client links
    # libncurses.so.5, which modern hosts no longer ship — it must exist HERE
    # so ldd resolves it and bundle-linux-deps copies it into lib/.
    sudo apt-get install -y patchelf libncurses5 libtinfo5

    plat="linux-systemd-x86_64"
    base="mariadb-${version}-${plat}"
    url="https://archive.mariadb.org/${ref}/bintar-${plat}/${base}.tar.gz"

    work="$(mktemp -d)"; cd "$work"
    echo "fetching $url"
    curl -fsSL "$url" -o mariadb.tar.gz
    tar -xzf mariadb.tar.gz
    src="$(find "$work" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    [ -n "$src" ] || { echo "no extracted dir from $base" >&2; exit 1; }
    curate "$src"
    ;;

  *)
    # ── Source arm (aarch64 Linux, macOS): upstream publishes no binaries.
    case "$triple" in
      *linux*)
        sudo apt-get update -y
        sudo apt-get install -y build-essential cmake bison pkg-config patchelf \
          libncurses-dev libssl-dev zlib1g-dev
        ;;
      *darwin*)
        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
        brew install cmake openssl@3 bison ncurses pkg-config || true
        # macOS ships bison 2.3; MariaDB's grammar needs 3.x.
        export PATH="$(brew --prefix bison)/bin:$PATH"
        export OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
        # CI runners preset SDKROOT to the CommandLineTools SDK while the
        # toolchain's libc++ comes from Xcode — a two-SDK mix that breaks every
        # C++ compile ("<cstddef> didn't find libc++'s <stddef.h>", nullptr_t
        # undeclared). `--sdk macosx` IGNORES the preset env and returns the
        # active Xcode's own SDK, so the C and C++ headers agree (kvrocks hit
        # the same class of problem; same incantation).
        export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
        export CMAKE_OSX_SYSROOT="$SDKROOT"
        ;;
    esac

    # The source tarball vendors every submodule (libmariadb, wsrep-lib, …) —
    # far more reliable than a recursive git clone.
    src="$(mktemp -d)/src"; mkdir -p "$src"
    url="https://archive.mariadb.org/${ref}/source/mariadb-${version}.tar.gz"
    echo "fetching $url"
    curl -fsSL "$url" | tar -xz -C "$src" --strip-components=1
    build="$(mktemp -d)/build"; mkdir -p "$build"; cd "$build"

    # A lean, portable server profile:
    # - system OpenSSL (bundle step relocates it), bundled PCRE2 (one less .so)
    # - no galera/wsrep, no unit tests, no embedded server
    # - heavy optional engines off: columnstore, rocksdb, mroonga, spider,
    #   connect, oqgraph, s3 — none has a doze use case, all bloat the build
    # - CMAKE_POLICY_VERSION_MINIMUM: CMake 4 dropped compat with the old
    #   minimums some MariaDB trees declare
    cmake "$src" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$prefix.install" \
      -DINSTALL_LAYOUT=STANDALONE \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DWITH_SSL=system \
      -DWITH_PCRE=bundled \
      -DWITH_WSREP=OFF \
      -DWITH_UNIT_TESTS=OFF \
      -DWITH_EMBEDDED_SERVER=OFF \
      -DWITH_SAFEMALLOC=OFF \
      -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO \
      -DPLUGIN_SPIDER=NO -DPLUGIN_SPHINX=NO -DPLUGIN_CONNECT=NO \
      -DPLUGIN_OQGRAPH=NO -DPLUGIN_S3=NO

    jobs="$(getconf _NPROCESSORS_ONLN)"
    make -j"$jobs"
    make install

    curate "$prefix.install"
    ;;
esac

# Relocate any bundled libs so nothing points at the build/extract path. Pick
# the script by triple and let a failure FAIL the build — running both with
# errors suppressed (as this once did) silently skipped genuine relocation
# problems and left the smoke gate as the only line of defense.
case "$triple" in
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" ;;
esac

"$root/scripts/package.sh" "$prefix" "mariadb-$version-$triple" "$out"
"$root/scripts/smoke.sh" mariadb "$out/mariadb-$version-$triple.tar.gz" "$triple"
