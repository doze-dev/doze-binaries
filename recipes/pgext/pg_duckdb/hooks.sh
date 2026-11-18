# shellcheck shell=bash

# pg_duckdb links libduckdb, built from the DuckDB git submodule its release
# tag pins (versions.yaml bundled: duckdb), with the json, icu, parquet and
# httpfs extensions compiled in (third_party/pg_duckdb_extensions.cmake; the
# httpfs commit is pinned there and in bundled: duckdb-httpfs).
#
# httpfs needs OpenSSL and libcurl. OpenSSL is the Postgres tree's own (the
# library the server already loads, so one copy is in the process); libcurl
# is the pinned release (bundled: curl), built static against that OpenSSL
# with every optional protocol library off, so nothing outside the tree and
# the OS is loaded at run time.
#
# DuckDB does not depend on Postgres, so libduckdb is built once per (triple,
# pinned set, this recipe) and cached; each major's build reuses it.

duckdb_cache_dir() {
  local key
  key="$( { echo "$1"; echo "${MACOSX_DEPLOYMENT_TARGET:-}"; env | grep '^PGEXT_DEP_' | sort; declare -f duckdb_build_curl pgext_hook_pre_build duckdb_openssl_root; } | shasum -a 256 | cut -c1-16)"
  echo "$PGEXT_CACHE/deps/duckdb-$key-$1"
}

# duckdb_openssl_root <pgtree>: an OPENSSL_ROOT_DIR whose libraries are the
# tree's. macOS: the tree's dylibs with Homebrew's headers (same 3.x line;
# headers only, at build time). Linux: the distro's dev package, whose
# libssl.so.3 is what the tree's own postgres links.
duckdb_openssl_root() {
  local pgtree="$1" r="$PGEXT_WORK/openssl"
  case "$(uname -s)" in
    Darwin)
      mkdir -p "$r/lib"
      ln -sfn "$(brew --prefix openssl@3)/include" "$r/include"
      ln -sf "$pgtree/lib/libssl.3.dylib" "$r/lib/libssl.dylib"
      ln -sf "$pgtree/lib/libcrypto.3.dylib" "$r/lib/libcrypto.dylib"
      echo "$r"
      ;;
    *) echo "" ;;
  esac
}

# duckdb_build_curl <prefix> <openssl root>: static libcurl, HTTP(S) only.
duckdb_build_curl() {
  local p="$1" ssl="$2" s
  s="$(pgext_dep_fetch curl "$PGEXT_WORK/deps/curl")"
  cmake -S "$s" -B "$s/_build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$p" \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
    -DCURL_USE_OPENSSL=ON ${ssl:+-DOPENSSL_ROOT_DIR="$ssl"} \
    -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF \
    -DUSE_NGHTTP2=OFF -DUSE_NGTCP2=OFF -DUSE_LIBIDN2=OFF -DUSE_APPLE_IDN=OFF \
    -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON \
    -DCURL_USE_PKGCONFIG=OFF \
    ${MACOSX_DEPLOYMENT_TARGET:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"} >&2 \
    && cmake --build "$s/_build" -j"$(pgext_ncpu)" >&2 \
    && cmake --install "$s/_build" >&2 || pgext_die "building curl"
  mkdir -p "$p/licenses/curl"; cp "$s/COPYING" "$p/licenses/curl/"
}

pgext_hook_deps() {
  local triple="$1"
  case "$triple" in
    *linux*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || sudo apt-get install -y cmake ninja-build libssl-dev ;;
    *darwin*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || brew install cmake ninja openssl@3 || true ;;
  esac
  command -v cmake >/dev/null || pgext_die "pg_duckdb needs cmake"
  DUCKDB_CACHE="$(duckdb_cache_dir "$triple")"
  # pg_duckdb links -llz4. The tree ships liblz4 (the one Postgres loads)
  # but no unversioned liblz4.dylib, and its PGXS flags put Homebrew's lz4
  # on the link line, which would be recorded (built for the host's macOS).
  # PG_LDFLAGS goes first on PGXS's link line: link the tree's instead.
  if [ "$(uname -s)" = Darwin ]; then
    local lz4
    lz4="$(ls "$("$PGEXT_PG_CONFIG" --libdir)"/liblz4.*.dylib 2>/dev/null | head -1)"
    [ -n "$lz4" ] || pgext_die "the Postgres tree ships no liblz4"
    mkdir -p "$PGEXT_WORK/lz4" && ln -sf "$lz4" "$PGEXT_WORK/lz4/liblz4.dylib"
    PGEXT_MAKE_ARGS+=("PG_LDFLAGS=-L$PGEXT_WORK/lz4")
    # The Makefile names libduckdb with the tree's DLSUFFIX, which is .so
    # before PG16 on macOS; CMake always builds libduckdb.dylib.
    PGEXT_MAKE_ARGS+=("FULL_DUCKDB_LIB=third_party/duckdb/build/release/src/libduckdb.dylib")
  fi
}

pgext_hook_pre_build() {
  local src="$PWD" want lib pgtree ssl gen=make
  git -C "$src" submodule update --init --depth 1 third_party/duckdb >&2 \
    || pgext_die "fetching the DuckDB submodule"
  want="$(git -C "$src/third_party/duckdb" rev-parse HEAD)"
  case "$PGEXT_DEP_DUCKDB_URL" in
    *"@$want") ;;
    *) pgext_die "pg_duckdb $PGEXT_VERSION pins DuckDB $want; versions.yaml bundles $PGEXT_DEP_DUCKDB_URL" ;;
  esac
  want="$(sed -nE 's/^[[:space:]]*GIT_TAG ([0-9a-f]+).*/\1/p' "$src/third_party/pg_duckdb_extensions.cmake")"
  case "$PGEXT_DEP_DUCKDB_HTTPFS_URL" in
    *"@$want") ;;
    *) pgext_die "pg_duckdb pins duckdb-httpfs $want; versions.yaml bundles $PGEXT_DEP_DUCKDB_HTTPFS_URL" ;;
  esac
  lib="libduckdb$([ "$(uname -s)" = Darwin ] && echo .dylib || echo .so)"
  pgtree="$("$PGEXT_PG_CONFIG" --bindir)/.."
  if [ ! -f "$DUCKDB_CACHE/.done" ]; then
    local t0; t0="$(date +%s)"
    rm -rf "$DUCKDB_CACHE"; mkdir -p "$DUCKDB_CACHE"
    ssl="$(duckdb_openssl_root "$pgtree")"
    # DuckDB 1.4 httpfs talks HTTP through libcurl; 1.3 through its own
    # httplib, so curl is bundled only where versions.yaml says so.
    local curlvars=""
    if [ -n "${PGEXT_DEP_CURL_URL:-}" ]; then
      duckdb_build_curl "$DUCKDB_CACHE/curl" "$ssl"
      curlvars=" -DCMAKE_PREFIX_PATH=$DUCKDB_CACHE/curl -DCURL_DIR=$DUCKDB_CACHE/curl/lib/cmake/CURL"
    fi
    command -v ninja >/dev/null && gen=ninja
    # pg_duckdb's own Makefile target, with CMake told where the pinned curl
    # and the tree's OpenSSL are.
    make -C "$src" duckdb PG_CONFIG="$PGEXT_PG_CONFIG" DUCKDB_GEN="$gen" ${PGEXT_MAKE_ARGS[@]+"${PGEXT_MAKE_ARGS[@]}"} \
      DUCKDB_CMAKE_VARS="-DCXX_EXTRA=-fvisibility=default -DBUILD_SHELL=0 -DBUILD_PYTHON=0 -DBUILD_UNITTESTS=0${curlvars}${ssl:+ -DOPENSSL_ROOT_DIR=$ssl}${MACOSX_DEPLOYMENT_TARGET:+ -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET}" >&2 \
      || pgext_die "building DuckDB"
    cp "$src/third_party/duckdb/build/release/src/$lib" "$DUCKDB_CACHE/"
    mkdir -p "$DUCKDB_CACHE/licenses/duckdb" "$DUCKDB_CACHE/licenses/duckdb-httpfs"
    cp "$src/third_party/duckdb/LICENSE" "$DUCKDB_CACHE/licenses/duckdb/"
    cp "$src"/third_party/duckdb/build/release/_deps/httpfs_extension_fc-src/LICENSE "$DUCKDB_CACHE/licenses/duckdb-httpfs/" 2>/dev/null \
      || find "$src/third_party/duckdb/build" -maxdepth 4 -path '*httpfs*' -name LICENSE -exec cp {} "$DUCKDB_CACHE/licenses/duckdb-httpfs/" \; -quit
    touch "$DUCKDB_CACHE/.done"
    pgext_log "pg_duckdb: libduckdb built in $(( $(date +%s) - t0 ))s"
  else
    pgext_log "pg_duckdb: libduckdb from the cache ($DUCKDB_CACHE)"
    mkdir -p "$src/third_party/duckdb/build/release/src"
    cp "$DUCKDB_CACHE/$lib" "$src/third_party/duckdb/build/release/src/"
    # Newer than everything the Makefile's duckdb target depends on.
    touch "$src/third_party/duckdb/build/release/src/$lib"
  fi
  local d
  for d in duckdb duckdb-httpfs; do
    pgext_dep_license "$d" "$DUCKDB_CACHE/licenses/$d"/*
  done
  [ -z "${PGEXT_DEP_CURL_URL:-}" ] || pgext_dep_license curl "$DUCKDB_CACHE/curl/licenses/curl"/*
}
