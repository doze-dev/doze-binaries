#!/usr/bin/env bash
# build-documentdb.sh <ddb_src> <pg_config> <deps> <triple> <icu_dir> <lib_dir> <ext_dir>
#
# Build + install the DocumentDB extensions (documentdb_core, documentdb api,
# documentdb_extended_rum) into the Postgres pointed at by <pg_config>.
#
# On Linux this is a stock PGXS build. macOS needs two things the Linux build gets
# for free, because Postgres loadable modules are Mach-O *bundles* with two-level
# namespaces:
#
#   - The api's SQL binds C functions like `bson_in` via `$libdir/pg_documentdb`,
#     but `bson_in` actually lives in documentdb_core. Postgres resolves it with
#     dlsym(handle_of_pg_documentdb, "bson_in"), which only searches that library
#     and its linked dependencies — NOT other globally-loaded modules. So core
#     must be a real **dylib** that the api **re-exports** (you can only re-export
#     a dylib, not a bundle), making core's symbols resolvable through the api.
#
#   - Because core is a plain dylib (no `-bundle_loader`), the linker would bind
#     the Postgres backend symbols it imports to whatever provides them — and
#     libSystem ALSO exports a `hash_search` (the db(3)/<search.h> one). That wrong
#     binding corrupts the heap the first time an index command deduplicates BSON
#     fields. We link core with **-flat_namespace** so those imports stay flat
#     (unbound) and resolve at runtime against the flat namespace, where the main
#     executable (postgres) is searched first — so `hash_search` binds to Postgres's
#     dynahash, not libc. (The api/extended_rum are bundles built with
#     `-bundle_loader .../postgres` by PGXS, so they already bind correctly.)
#
# We let PGXS build+install the stock artifacts (for the SQL/control and the
# bundles), then overwrite core and the api with the correctly-linked versions.
set -euo pipefail

DDB="$1"; PGC="$2"; DEPS="$3"; TRIPLE="$4"; ICU_DIR="$5"; LIB_DIR="$6"; EXT_DIR="$7"
cd "$DDB"
ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
COPT="-Wno-error"
is_darwin() { case "$TRIPLE" in *darwin*) return 0 ;; *) return 1 ;; esac; }

if is_darwin; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
  PCRE_DIR="$(brew --prefix pcre2 2>/dev/null)"
  # static bson+intel (no runtime dep) + dynamic pcre2/icu, shared by both libs
  DDB_LIBS=(-L"$DEPS/lib" -lbson-static-1.0 -L"$DEPS/intelmath/LIBRARY" -lbid
            -L"$PCRE_DIR/lib" -lpcre2-8 -L"$ICU_DIR/lib" -licui18n -licuuc -licudata)
fi

# 1. documentdb_core — build, install (bundle+SQL+control), then on macOS swap the
#    bundle for a FLAT-namespace dylib: it exports core's symbols (so the api can
#    re-export them) while leaving its Postgres-backend imports unbound, so
#    hash_search resolves to the postgres executable at runtime, not libSystem.
make -C pg_documentdb_core -j"$ncpu" PG_CONFIG="$PGC" COPT="$COPT"
make -C pg_documentdb_core    PG_CONFIG="$PGC" COPT="$COPT" install
if is_darwin; then
  ( cd pg_documentdb_core
    clang -dynamiclib -install_name "$LIB_DIR/pg_documentdb_core.dylib" \
      -o pg_documentdb_core.dylib $(find src -name '*.o') \
      "${DDB_LIBS[@]}" -Wl,-flat_namespace -Wl,-undefined,dynamic_lookup ${SDK:+-isysroot "$SDK"} )
  cp -f pg_documentdb_core/pg_documentdb_core.dylib "$LIB_DIR/pg_documentdb_core.dylib"
fi

# 2. documentdb (api) — build, install, then on macOS relink the bundle to
#    re-export core so dlsym finds core's functions through the api library.
#    Built BEFORE extended_rum: upstream's order is core -> api -> extended_rum,
#    and extended_rum (USE_DOCUMENTDB=1) links `-l:pg_documentdb.so`, so the api
#    must already exist on Linux. The api is a bundle with -bundle_loader, so its
#    own Postgres imports (incl. hash_search) bind to the executable correctly.
make -C pg_documentdb -j"$ncpu" PG_CONFIG="$PGC" COPT="$COPT"
make -C pg_documentdb    PG_CONFIG="$PGC" COPT="$COPT" install
if is_darwin; then
  PGBIN="$($PGC --bindir)/postgres"
  ( cd pg_documentdb
    clang -bundle -o pg_documentdb.dylib $(find src -name '*.o') \
      -Wl,-reexport_library "$LIB_DIR/pg_documentdb_core.dylib" \
      "${DDB_LIBS[@]}" -bundle_loader "$PGBIN" \
      -Wl,-undefined,dynamic_lookup ${SDK:+-isysroot "$SDK"} )
  cp -f pg_documentdb/pg_documentdb.dylib "$LIB_DIR/pg_documentdb.dylib"
fi

# 3. documentdb_extended_rum (the RUM index access method DocumentDB preloads).
#    Depends on the api above (-l:pg_documentdb.so on Linux).
make -C pg_documentdb_extended_rum -j"$ncpu" PG_CONFIG="$PGC" COPT="$COPT"
make -C pg_documentdb_extended_rum    PG_CONFIG="$PGC" COPT="$COPT" install

echo "documentdb extensions installed into $LIB_DIR"
