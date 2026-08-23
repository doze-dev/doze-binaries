#!/usr/bin/env bash
# recipes/mariadb/build.sh <version> <ref> <triple> <out_dir>
#   version   e.g. 11.4.5
#   ref       e.g. mariadb-11.4.5   (the upstream release directory name)
#
# ONE arm, one curated layout: every triple BUILDS FROM SOURCE (the postgres
# approach) — upstream's source tarball (submodules vendored), a lean server
# profile (no wsrep, no columnstore/rocksdb/mroonga/spider — heavy engines with
# no doze use case), installed with the standalone layout and then curated, so
# every triple ships an identical tree: bin/{mariadbd,mariadb,mariadb-admin,
# mariadb-install-db,…}, share/, lib/plugin.
#
# That claim is no longer just a comment. scripts/parity.sh diffs a version's
# triples at release time and fails the publish if they disagree — which is what
# this recipe needed, because for a long time the sentence above was false:
#
#   x86_64 Linux used to REPACKAGE upstream's generic bintar (the only triple
#   MariaDB publishes one for) instead of building. That was much faster, but
#   the bintar is a DIFFERENT tree: it ships auth_pam/auth_gssapi and omits the
#   server-side auth_parsec, auth_mysql_sha2 and sha256_password entirely
#   (MariaDB packages PARSEC separately; the bintar's parsec.so is the CLIENT
#   plugin, and loading that as a server plugin fails with "Can't find symbol
#   '_mysql_plugin_interface_version_'" — it reads like corruption, not absence).
#   So `settings = { plugin_load_add = "auth_parsec" }` in a doze config worked
#   on arm64 and broke on x86_64, with no way to see that coming.
#
# Published artifacts are immutable, so unifying the arms can only ever apply to
# NEW versions: every mariadb version listed in scripts/parity-waivers.txt was
# built under the old two-arm recipe and keeps its divergent x86_64 tree forever.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/mariadb"; mkdir -p "$prefix/bin" "$prefix/share" "$prefix/lib"

# curate <tree>: copy the pieces doze actually runs from an install prefix into
# $prefix, so the shipped layout is a deliberate selection rather than whatever
# `make install` happened to lay down.
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

  # Belt-and-braces drop list. The cmake profile below already excludes these
  # (-DPLUGIN_*=NO, -DWITH_WSREP=OFF), so on a clean runner this removes
  # nothing — it exists so a runner that happens to have libJudy or libcrack
  # installed can't quietly add an OQGraph/cracklib plugin that links a system
  # library doze doesn't ship, which would trip smoke.sh's relocation gate on
  # one triple and hand parity.sh a divergence to report.
  for p in ha_rocksdb ha_mroonga ha_connect ha_spider ha_sphinx ha_s3 \
           ha_columnstore ha_oqgraph ha_duckdb provider_snappy wsrep_info \
           cracklib_password_check; do
    rm -f "$prefix/lib/plugin/$p.so" "$prefix/lib/plugin/$p.dylib"
  done
}

case "$triple" in
  *linux*)
    sudo apt-get update -y
    sudo apt-get install -y build-essential cmake bison pkg-config patchelf \
      libncurses-dev libssl-dev zlib1g-dev
    # These are not optional extras — each one gates a plugin, and MariaDB
    # SKIPS a plugin whose headers are missing without failing, or even warning
    # loudly, at cmake time. Leaving them out is precisely how the Linux source
    # arm came to ship a smaller plugin set than the macOS source arm running
    # the identical cmake line:
    #   libpam0g-dev        -> auth_pam, auth_pam_v1, auth_pam_tool,
    #                          share/pam_user_map.so, share/user_map.conf
    #   libkrb5-dev         -> auth_gssapi, auth_gssapi_client
    #   libcurl4-openssl-dev-> hashicorp_key_management (Vault-backed key mgmt)
    #   liblzo2-dev         -> provider_lzo (LZO page compression)
    #   libbz2-dev          -> provider_bzip2
    #   liblzma-dev         -> provider_lzma
    # The last two were the parity gate's first catch: they build on
    # ubuntu-22.04 (something else on that image drags the headers in) but not
    # on ubuntu-latest, so the plugin set silently depended on the runner image
    # rather than on anything this recipe declares.
    # There is no cmake flag that turns the silence into an error: each plugin's
    # CMakeLists RETURNs before MYSQL_ADD_PLUGIN when its dependency is absent,
    # so -DPLUGIN_AUTH_PAM=DYNAMIC wouldn't fail either. The plugin set can only
    # be asserted on the ARTIFACT — see scripts/parity.sh.
    sudo apt-get install -y libpam0g-dev libkrb5-dev libcurl4-openssl-dev \
      liblzo2-dev libbz2-dev liblzma-dev
    ;;
  *darwin*)
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
    # lzo is here for the same reason as liblzo2-dev above: provider_lzo built
    # on the macOS runners only because something else had pulled lzo in, which
    # is ambient state, not a decision. PAM, GSSAPI and curl come from the SDK.
    brew install cmake openssl@3 bison ncurses pkg-config lzo || true
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
    # Even with the sysroot pinned, MariaDB's find_path calls (curses,
    # zlib) locate headers inside the CommandLineTools SDK on CI images
    # that have both toolchains, and inject that SDK's whole usr/include —
    # shadowing libc++'s C stubs and failing every C++ TU. On CI, remove
    # the CLT so no find can resolve into it (Xcode provides everything);
    # never on a developer machine.
    if [ -n "${CI:-}" ] && [ -d /Library/Developer/CommandLineTools ]; then
      sudo rm -rf /Library/Developer/CommandLineTools
    fi
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
#   connect, oqgraph, s3, duckdb — none has a doze use case, all bloat the build
#
#   DUCKDB is off for a second reason as well: upstream builds it on Linux ONLY
#   ("-- DuckDB: not Linux, skipping" on macOS), so while it ships there is no
#   way for every triple to carry the same tree — the parity gate caught exactly
#   that on 11.4.13, 11.8.9 and 12.3.3 and refused to publish them. It also
#   compiles DuckDB from a bundled submodule with its own parquet/json/icu
#   extensions, which is a lot of build time and ~20MB of artifact for an
#   analytics engine doze never starts.
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
  -DWITH_ZLIB=bundled \
  -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO \
  -DPLUGIN_SPIDER=NO -DPLUGIN_SPHINX=NO -DPLUGIN_CONNECT=NO \
  -DPLUGIN_OQGRAPH=NO -DPLUGIN_S3=NO -DPLUGIN_DUCKDB=NO \
  $(if [ "${triple#*darwin}" != "$triple" ]; then
      nc="$(brew --prefix ncurses)"
      echo "-DCURSES_INCLUDE_PATH=$nc/include -DCURSES_LIBRARY=$nc/lib/libncurses.dylib"
    fi)

jobs="$(getconf _NPROCESSORS_ONLN)"
make -j"$jobs"
make install

curate "$prefix.install"

# Relocate any bundled libs so nothing points at the build path. Pick the script
# by triple and let a failure FAIL the build — running both with errors
# suppressed (as this once did) silently skipped genuine relocation problems and
# left the smoke gate as the only line of defense.
case "$triple" in
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" ;;
esac

"$root/scripts/package.sh" "$prefix" "mariadb-$version-$triple" "$out"
"$root/scripts/smoke.sh" mariadb "$out/mariadb-$version-$triple.tar.gz" "$triple"
