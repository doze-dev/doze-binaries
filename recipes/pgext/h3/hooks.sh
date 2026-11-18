# shellcheck shell=bash

# h3-pg builds with CMake (there is no PGXS Makefile) and links the H3 core
# library statically. Its CMake would download the core tarball itself; the
# build hands it the one versions.yaml pins instead (bundled: h3, same URL and
# sha256), unpacked by pgext_dep_fetch, and fails if h3-pg asks for another.

pgext_hook_deps() {
  local triple="$1"
  case "$triple" in
    *linux*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || sudo apt-get install -y cmake ;;
    *darwin*) [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || brew install cmake || true ;;
  esac
  command -v cmake >/dev/null || pgext_die "h3 needs cmake"
  H3_CORE_SRC="$(pgext_dep_fetch h3 "$PGEXT_WORK/deps/h3")"
  pgext_dep_license h3 "$H3_CORE_SRC/LICENSE"
}

pgext_hook_build() {
  local src="$1" pgc="$2" want asneeded
  # FindPostgreSQL links libpq into the modules, which use none of it: drop
  # unused libraries so the bundle does not vendor libpq and OpenSSL for nothing.
  case "$(uname -s)" in Darwin) asneeded="-Wl,-dead_strip_dylibs" ;; *) asneeded="-Wl,--as-needed" ;; esac
  want="$(sed -nE 's/^set\(H3_CORE_VERSION ([0-9.]+)\)/\1/p' "$src/CMakeLists.txt")"
  [ "$want" = "$PGEXT_DEP_H3_VERSION" ] \
    || pgext_die "h3-pg $PGEXT_VERSION wants H3 core $want; versions.yaml bundles $PGEXT_DEP_H3_VERSION"
  cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
    -DPostgreSQL_CONFIG="$pgc" -DBUILD_TESTING=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$asneeded" -DCMAKE_MODULE_LINKER_FLAGS="$asneeded" \
    -DFETCHCONTENT_SOURCE_DIR_H3="$H3_CORE_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    ${MACOSX_DEPLOYMENT_TARGET:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"} \
    ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"}
  cmake --build "$src/build" -j"$(pgext_ncpu)"
  DESTDIR="$PGEXT_STAGE" cmake --install "$src/build" --component h3-pg
}
