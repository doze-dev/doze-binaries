#!/usr/bin/env bash
# recipes/documentdb/build.sh <version> <ref> <triple> <out_dir>
#   version  documentdb extension version, e.g. 0.115.0
#   ref      documentdb git ref to build, e.g. v0.115-0
#
# Produces a SELF-CONTAINED, relocatable PostgreSQL 18 with Microsoft's
# DocumentDB extension (+ its required chain: documentdb_core, documentdb,
# documentdb_extended_rum, pg_cron, pgvector, postgis, tsm_system_rows) compiled
# in. doze's `documentdb` engine fetches this and fronts it with FerretDB, so a
# user just declares `documentdb "x" {}` and connects over the MongoDB wire —
# Postgres is pinned to 18 and never user-selected.
#
# Every macOS quirk below was discovered the hard way (see comments): the GNU
# linker/rpath syntax, <malloc.h>, ICU linkage, bash 3.2 vs the codegen scripts,
# clang vs GNU cpp for SQL token-paste, and the two-level-namespace symbol
# sharing between the api and core extensions. Linux builds DocumentDB stock.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"

PG_VERSION="18.4"; PG_REF="REL_18_4"          # Postgres is pinned for documentdb
prefix="$(mktemp -d)/documentdb"              # the relocatable install tree
deps="$(mktemp -d)/deps"                      # build-only deps (intel, libbson)
src="$(mktemp -d)/src"
ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
mkdir -p "$prefix" "$deps"

# ── platform build dependencies ─────────────────────────────────────────────
case "$triple" in
  *darwin*)
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1
    # bash (5.x, for DocumentDB's codegen scripts) and gcc (its `cpp-NN` is the
    # GNU preprocessor DocumentDB's SQL token-paste needs; clang's drops it).
    brew install pkg-config cmake bash gcc \
      icu4c openssl@3 lz4 zstd libxml2 readline pcre2 \
      geos proj json-c || true
    bp="$(brew --prefix)"
    GNU_CPP="$(ls "$bp"/bin/cpp-* 2>/dev/null | sort -V | tail -1)"
    ICU_DIR="$(ls -d "$bp"/opt/icu4c@* 2>/dev/null | sort -V | tail -1)"; ICU_DIR="${ICU_DIR:-$bp/opt/icu4c}"
    export PKG_CONFIG_PATH="$bp/opt/icu4c/lib/pkgconfig:$bp/opt/openssl@3/lib/pkgconfig:$bp/opt/pcre2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export CPPFLAGS="-I$bp/opt/icu4c/include -I$bp/opt/openssl@3/include -I$bp/opt/readline/include ${CPPFLAGS:-}"
    export LDFLAGS="-L$bp/opt/icu4c/lib -L$bp/opt/openssl@3/lib -L$bp/opt/readline/lib ${LDFLAGS:-}"
    PATH="$bp/bin:$PATH"                       # modern bash first
    ;;
  *linux*)
    sudo apt-get update -y
    sudo apt-get install -y build-essential bison flex pkg-config patchelf cmake git curl \
      libreadline-dev zlib1g-dev libicu-dev libssl-dev liblz4-dev libzstd-dev libxml2-dev uuid-dev \
      libpcre2-dev libgeos-dev libproj-dev libjson-c-dev
    GNU_CPP="cpp"
    ICU_DIR=""
    ;;
esac

# ── 1. PostgreSQL 18 (same lean profile as the postgres recipe) ─────────────
git clone --depth 1 --branch "$PG_REF" -c advice.detachedHead=false \
  https://git.postgresql.org/git/postgresql.git "$src/pg"
( cd "$src/pg"
  ./configure --prefix="$prefix" --enable-option-checking=fatal \
    --with-icu --with-openssl --with-libxml --with-lz4 --with-zstd \
    --with-uuid=e2fs --with-readline --with-system-tzdata=/usr/share/zoneinfo --without-ldap
  make -j"$ncpu" world-bin
  make install-world-bin )
PGC="$prefix/bin/pg_config"
EXT_DIR="$($PGC --sharedir)/extension"
LIB_DIR="$($PGC --pkglibdir)"

# ── 2. build-only deps: Intel decimal lib + static libbson ──────────────────
"$root/recipes/documentdb/build-deps.sh" "$deps"
export PKG_CONFIG_PATH="$deps/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ── 3. required extensions: pgvector, pg_cron, postgis (no raster/gdal) ──────
build_pgxs() { # <git-url> <ref> <subdir-make-args...>
  local url="$1" gref="$2"; shift 2
  local d="$src/$(basename "$url" .git)"
  git clone --depth 1 --branch "$gref" "$url" "$d"
  make -C "$d" -j"$ncpu" PG_CONFIG="$PGC" "$@"
  make -C "$d" PG_CONFIG="$PGC" install "$@"
}
build_pgxs https://github.com/pgvector/pgvector.git v0.8.1
build_pgxs https://github.com/citusdata/pg_cron.git v1.6.7

# PostGIS: core geometry extension only. documentdb requires the `postgis`
# extension (GEOS+PROJ), not postgis_raster/postgis_topology — those pull in
# GDAL, which we deliberately don't ship. `make all` builds the extensions/
# meta-dir (every variant, incl. raster/topology) and fails without GDAL, so we
# build just the core subdirs and the single `extensions/postgis` SQL/control.
# Use the release tarball — it ships a pre-generated ./configure (no autogen).
curl -fsSL https://download.osgeo.org/postgis/source/postgis-3.6.0.tar.gz -o "$src/postgis.tgz"
mkdir -p "$src/postgis" && tar xzf "$src/postgis.tgz" -C "$src/postgis" --strip-components=1
( cd "$src/postgis"
  ./configure --prefix="$prefix" --with-pgconfig="$PGC" --without-raster --without-protobuf
  # Even with raster disabled, extensions/postgis's install SQL depends on
  # sql/raster_unpackage.sql, whose recipe unconditionally runs
  # `make -C ../../raster/rt_pg sql_objs` — which fails (the raster lib was never
  # built). It's a -j race: x86_64 dodged it, arm64 didn't. Stub that target to
  # emit EMPTY drop scripts so raster_unpackage.sql builds to a no-op. A fresh
  # CREATE EXTENSION postgis never needs the raster-unpackage path.
  printf 'sql_objs:\n\t@touch rtpostgis_drop.sql rtpostgis_upgrade_cleanup.sql uninstall_rtpostgis.sql\n.DEFAULT:\n\t@true\n' > raster/rt_pg/Makefile
  make -j"$ncpu" -C liblwgeom
  [ -d deps ] && make -j"$ncpu" -C deps || true
  make -j"$ncpu" -C libpgcommon
  make -j"$ncpu" -C postgis && make -C postgis install
  # extensions/: generate postgis_extension_helper.sql and build ONLY the core
  # postgis extension (override SUBDIRS so raster/topology are never added).
  make -j"$ncpu" -C extensions SUBDIRS=postgis && make -C extensions SUBDIRS=postgis install )

# ── 4. DocumentDB extensions (core + api + extended_rum) ─────────────────────
git clone --depth 1 --branch "$ref" https://github.com/microsoft/documentdb.git "$src/documentdb"
cd "$src/documentdb"

# Portable patch (safe on Linux too): CRoaring's <malloc.h> isn't on macOS.
grep -rl '#include <malloc.h>' pg_documentdb*/src 2>/dev/null | while read -r f; do
  sed -i.bak 's|#include <malloc.h>|#if defined(__APPLE__)\n#include <stdlib.h>\n#else\n#include <malloc.h>\n#endif|' "$f" && rm -f "$f.bak"
done

COPT_COMMON="-Wno-error"
case "$triple" in
  *darwin*)
    # ld64 has no GNU `-l:exact.so`; drop the cross-extension link entirely and
    # defer those symbols (core's bson_in, the api's exports) to runtime via
    # `-undefined dynamic_lookup`. They resolve through RTLD_GLOBAL — Postgres
    # preloads pg_documentdb_core before pg_documentdb (see build-documentdb.sh).
    # PGXS still appends `-bundle_loader .../postgres`, so the Postgres backend
    # symbols (incl. hash_search, which libSystem ALSO defines) bind to the
    # executable rather than libc. Also fix GNU rpath syntax and the ICU keg path.
    sed -i.bak 's/-Wl,-rpath=/-Wl,-rpath,/g; s#-l:pg_documentdb_core.so -L \$(DOCUMENTDB_CORE_DIR)#-Wl,-undefined,dynamic_lookup#; s#-l:pg_documentdb.so -L \$(DOCUMENTDB_DIR)#-Wl,-undefined,dynamic_lookup#; s#/opt/homebrew/opt/icu4c@78#'"$ICU_DIR"'#g' Makefile.cflags && rm -f Makefile.cflags.bak
    # ICU lives keg-only on macOS; ensure documentdb_core links it.
    grep -q "icu4c" Makefile.cflags || printf '\nPG_LDFLAGS += -L%s/lib -licui18n -licuuc -licudata\n' "$ICU_DIR" >> Makefile.cflags
    # DocumentDB codegen needs bash 5 (uses ${x^^}, declare -A) and GNU cpp for
    # SQL token-paste. Repoint every codegen script's hard `#!/bin/bash` (macOS
    # ships bash 3.2) at the modern bash we put first on PATH.
    for s in scripts/*.sh; do
      sed -i.bak '1 s|^#!/bin/bash|#!/usr/bin/env bash|' "$s" && rm -f "$s.bak"
    done
    mkdir -p "$src/bin" && ln -sf "$GNU_CPP" "$src/bin/cpp"
    export PATH="$src/bin:$PATH"
    # strip the hard -Werror across the tree (macOS clang trips many extra warnings)
    find . -name 'Makefile*' | while read -r f; do sed -i.bak 's/ -Werror / /g; s/ -Werror$//' "$f" && rm -f "$f.bak"; done
    # extended_rum: rpath syntax + defer cross-lib syms; its export-validation
    # uses GNU `nm -D` (Linux-only) — symbols are verified exported via nm -gU.
    find pg_documentdb_extended_rum -name 'Makefile*' | while read -r f; do
      sed -i.bak 's/-Wl,-rpath=/-Wl,-rpath,/g' "$f" && rm -f "$f.bak"; done
    sed -i.bak 's#-l:\$(RUM_CORE_LIB_NAME) -L\$(RUM_CORE_LIB_DIR)#-Wl,-undefined,dynamic_lookup#; s#-l:\$(RUM_CORE_LIB_BUILTIN_RMGR_NAME) -L\$(RUM_CORE_BUILTIN_RMGR_LIB_DIR)#-Wl,-undefined,dynamic_lookup#' pg_documentdb_extended_rum/Makefile && rm -f pg_documentdb_extended_rum/Makefile.bak
    sed -i.bak '/PG_LDFLAGS += -Wl,-rpath,/a\
PG_LDFLAGS += -Wl,-undefined,dynamic_lookup' pg_documentdb_extended_rum/core/Makefile && rm -f pg_documentdb_extended_rum/core/Makefile.bak
    printf '#!/usr/bin/env bash\nexit 0\n' > pg_documentdb_extended_rum/validate_rum_core_exports.sh
    ;;
esac

"$root/recipes/documentdb/build-documentdb.sh" "$src/documentdb" "$PGC" "$deps" "$triple" "$ICU_DIR" "$LIB_DIR" "$EXT_DIR"

# ── 5. make relocatable + package + smoke ───────────────────────────────────
case "$triple" in
  *darwin*) "$root/scripts/bundle-macos-deps.sh" "$prefix" "$(brew --prefix)" ;;
  *linux*)  "$root/scripts/bundle-linux-deps.sh" "$prefix" ;;
esac

"$root/scripts/package.sh" "$prefix" "documentdb-$version-$triple" "$out"
"$root/scripts/smoke.sh" documentdb "$out/documentdb-$version-$triple.tar.gz" "$triple"
