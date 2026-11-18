# shellcheck shell=bash

# pgRouting builds with CMake against Boost.Graph, which is header-only: the
# pinned Boost (versions.yaml bundled: boost) is unpacked and used for its
# headers alone; nothing of it ships but what the templates compile into the
# module, and its licence.

pgext_hook_deps() {
  local triple="$1"
  case "$triple" in
    *linux*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || sudo apt-get install -y cmake ;;
    *darwin*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || brew install cmake || true ;;
  esac
  command -v cmake >/dev/null || pgext_die "pgrouting needs cmake"
  BOOST_SRC="$(pgext_dep_fetch boost "$PGEXT_WORK/deps/boost")"
  pgext_dep_license boost "$BOOST_SRC/LICENSE_1_0.txt"
}

pgext_hook_build() {
  local src="$1" pgc="$2" asneeded
  # Link only what the module uses (FindPostgreSQL-style link lines can pull
  # in libpq, which would then be vendored for nothing).
  case "$(uname -s)" in Darwin) asneeded="-Wl,-dead_strip_dylibs" ;; *) asneeded="-Wl,--as-needed" ;; esac
  cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
    -DPOSTGRESQL_PG_CONFIG="$pgc" \
    -DBoost_INCLUDE_DIR="$BOOST_SRC" -DBOOST_ROOT="$BOOST_SRC" -DBoost_NO_SYSTEM_PATHS=ON \
    -DWITH_DOC=OFF -DBUILD_HTML=OFF -DBUILD_DOXY=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$asneeded" -DCMAKE_MODULE_LINKER_FLAGS="$asneeded" \
    ${MACOSX_DEPLOYMENT_TARGET:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"} \
    ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"}
  cmake --build "$src/build" -j"$(pgext_ncpu)"
  DESTDIR="$PGEXT_STAGE" cmake --install "$src/build"
}
