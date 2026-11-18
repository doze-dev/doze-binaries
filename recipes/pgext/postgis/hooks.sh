# shellcheck shell=bash

# PostGIS: autotools, against GEOS, PROJ (+ SQLite for proj.db), GDAL (for
# postgis_raster), json-c (GeoJSON), protobuf-c (MVT/Geobuf) and PCRE2 (the
# address standardizer). Every one is built from the tarball versions.yaml
# pins (bundled:), with the bundle's deployment target, into a prefix cached
# per (triple, pinned set, this file); relocation then copies the shared
# libraries the modules load into the bundle's lib/. Nothing comes from
# Homebrew or the distro at run time. libxml2 and iconv are what the
# Postgres engine itself links (macOS: the OS's), so PostGIS uses those.
#
# GDAL is built minimal: no external libraries but PROJ, its core raster
# drivers (GTiff, MEM, VRT, COG …) plus PNG and JPEG from GDAL's internal
# copies, no OGR vector drivers beyond the core, no apps or bindings.
#
# Build tools only (nothing of them ships): cmake, autoconf/automake/libtool
# (PostGIS's git tag has no configure), and protoc-c, which generates the C
# for PostGIS's two .proto files; the runtime is the pinned protobuf-c.

postgis_deps_prefix() {
  local key
  key="$( { echo "$1"; echo "${MACOSX_DEPLOYMENT_TARGET:-}"; env | grep '^PGEXT_DEP_' | sort; declare -f postgis_build_deps postgis_cmake; } | shasum -a 256 | cut -c1-16)"
  echo "$PGEXT_CACHE/deps/postgis-$key-$1"
}

postgis_cmake() { # <src> <prefix> <cmake args…>
  local s="$1" p="$2"; shift 2
  cmake -S "$s" -B "$s/_build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$p" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$p" -DBUILD_TESTING=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_NAME_DIR="$p/lib" -DCMAKE_INSTALL_RPATH="$p/lib" \
    ${MACOSX_DEPLOYMENT_TARGET:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"} \
    ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"} "$@" >&2
  cmake --build "$s/_build" -j"$(pgext_ncpu)" >&2
  cmake --install "$s/_build" >&2
}

# postgis_build_deps <prefix>: build every pinned library into <prefix>, and
# keep each one's licence under <prefix>/licenses/<name>/.
postgis_build_deps() {
  local p="$1" w s
  w="$PGEXT_WORK/deps"
  # Built straight into the prefix; .done marks it complete, so an interrupted
  # build is redone from scratch.
  rm -rf "$p"; mkdir -p "$p/licenses"
  local pt="$p"
  export PKG_CONFIG_PATH="$pt/lib/pkgconfig" PATH="$pt/bin:$PATH" LD_LIBRARY_PATH="$pt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  s="$(pgext_dep_fetch sqlite "$w/sqlite")"
  (cd "$s" && CFLAGS="-O2 -fPIC -DSQLITE_ENABLE_RTREE=1 -DSQLITE_ENABLE_COLUMN_METADATA=1" \
     ./configure --prefix="$pt" --disable-static --disable-readline >&2 && make -j"$(pgext_ncpu)" >&2 && make install >&2) \
    || pgext_die "building sqlite"
  # SQLite is public domain: no licence file; its blessing is in sqlite3.h.
  mkdir -p "$pt/licenses/sqlite"
  sed -n '1,/\*\*\*\*\*\*\*\*\*\*\*/p' "$s/sqlite3.h" > "$pt/licenses/sqlite/LICENSE-blessing.txt"

  s="$(pgext_dep_fetch proj "$w/proj")"
  postgis_cmake "$s" "$pt" -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DBUILD_APPS=OFF \
    -DBUILD_SHARED_LIBS=ON -DEXE_SQLITE3="$pt/bin/sqlite3" \
    -DSQLite3_INCLUDE_DIR="$pt/include" -DSQLite3_LIBRARY="$pt/lib/libsqlite3$(postgis_dlext)" \
    || pgext_die "building proj"
  mkdir -p "$pt/licenses/proj"; cp "$s/COPYING" "$pt/licenses/proj/"

  s="$(pgext_dep_fetch geos "$w/geos")"
  postgis_cmake "$s" "$pt" -DBUILD_BENCHMARKS=OFF -DBUILD_DOCUMENTATION=OFF || pgext_die "building geos"
  mkdir -p "$pt/licenses/geos"; cp "$s/COPYING" "$pt/licenses/geos/"

  s="$(pgext_dep_fetch json-c "$w/json-c")"
  postgis_cmake "$s" "$pt" -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DDISABLE_WERROR=ON \
    -DBUILD_APPS=OFF || pgext_die "building json-c"
  mkdir -p "$pt/licenses/json-c"; cp "$s/COPYING" "$pt/licenses/json-c/"

  s="$(pgext_dep_fetch protobuf-c "$w/protobuf-c")"
  (cd "$s" && ./configure --prefix="$pt" --disable-static --disable-protoc >&2 \
     && make -j"$(pgext_ncpu)" >&2 && make install >&2) || pgext_die "building protobuf-c"
  mkdir -p "$pt/licenses/protobuf-c"; cp "$s/LICENSE" "$pt/licenses/protobuf-c/"

  s="$(pgext_dep_fetch pcre2 "$w/pcre2")"
  (cd "$s" && ./configure --prefix="$pt" --disable-static --enable-shared >&2 \
     && make -j"$(pgext_ncpu)" >&2 && make install >&2) || pgext_die "building pcre2"
  mkdir -p "$pt/licenses/pcre2"; cp "$s/LICENCE.md" "$pt/licenses/pcre2/"

  s="$(pgext_dep_fetch gdal "$w/gdal")"
  postgis_cmake "$s" "$pt" -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF \
    -DGDAL_USE_EXTERNAL_LIBS=OFF -DGDAL_USE_PROJ=ON \
    -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
    -DGDAL_ENABLE_DRIVER_PNG=ON -DGDAL_USE_PNG_INTERNAL=ON \
    -DGDAL_ENABLE_DRIVER_JPEG=ON -DGDAL_USE_JPEG_INTERNAL=ON \
    -DGDAL_USE_ZLIB_INTERNAL=ON -DGDAL_USE_TIFF_INTERNAL=ON -DGDAL_USE_GEOTIFF_INTERNAL=ON \
    -DGDAL_USE_JSONC_INTERNAL=ON \
    -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_JAVA_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
    || pgext_die "building gdal"
  # LICENSE.TXT carries the notices of the third-party code GDAL builds in
  # (libtiff, libgeotiff, libpng, libjpeg, zlib, json-c, qhull …).
  mkdir -p "$pt/licenses/gdal"; cp "$s/LICENSE.TXT" "$pt/licenses/gdal/"

  touch "$p/.done"
}

postgis_dlext() { [ "$(uname -s)" = Darwin ] && echo .dylib || echo .so; }

pgext_hook_deps() {
  local triple="$1" d
  case "$triple" in
    *linux*)
      [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] \
        || sudo apt-get install -y cmake autoconf automake libtool protobuf-c-compiler libxml2-dev
      ;;
    *darwin*)
      [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] || brew install cmake autoconf automake libtool protobuf-c || true
      ;;
  esac
  for d in cmake autoconf automake protoc-c; do
    command -v "$d" >/dev/null || pgext_die "postgis needs $d to build"
  done
  POSTGIS_DEPS="$(postgis_deps_prefix "$triple")"
  if [ -f "$POSTGIS_DEPS/.done" ]; then
    pgext_log "postgis: bundled libraries from the cache ($POSTGIS_DEPS)"
  else
    local t0; t0="$(date +%s)"
    pgext_log "postgis: building the bundled libraries into $POSTGIS_DEPS"
    postgis_build_deps "$POSTGIS_DEPS"
    pgext_log "postgis: bundled libraries built in $(( $(date +%s) - t0 ))s"
  fi
  for d in $PGEXT_BUNDLED; do
    pgext_dep_license "$d" "$POSTGIS_DEPS/licenses/$d"/*
  done
  export PATH="$POSTGIS_DEPS/bin:$PATH" PKG_CONFIG_PATH="$POSTGIS_DEPS/lib/pkgconfig"
  export LD_LIBRARY_PATH="$POSTGIS_DEPS/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export PGEXT_EXTRA_LIBDIRS="$POSTGIS_DEPS/lib"
}

pgext_hook_build() {
  local src="$1" pgc="$2" p="$POSTGIS_DEPS"
  ./autogen.sh >&2 || pgext_die "postgis autogen.sh"
  # LDFLAGS: on Linux the modules carry no rpath to the cache (relocation
  # sets $ORIGIN); ldd finds them through PGEXT_EXTRA_LIBDIRS meanwhile.
  # bindir: the loaders install there (the tree's bin, which collect maps to
  # bin/ and post_collect drops); configure's default is /usr/local/bin.
  # mandir: under docdir, which collect drops.
  # Linux: configure links wagyu/flatgeobuf against libc++ whenever one is
  # installed (the CI runners have LLVM's), which would then be vendored and
  # loaded beside the libstdc++ GEOS/GDAL use. The C++ runtime is the
  # system's libstdc++, like every other C++ library here.
  local nocxx=()
  [ "$(uname -s)" = Darwin ] || nocxx=(ac_cv_lib_cpp_main=no)
  ./configure --with-pgconfig="$pgc" --bindir="$("$pgc" --bindir)" \
    ${nocxx[@]+"${nocxx[@]}"} \
    --mandir="$("$pgc" --docdir)/man" \
    --with-geosconfig="$p/bin/geos-config" --with-projdir="$p" \
    --with-gdalconfig="$p/bin/gdal-config" --with-jsondir="$p" \
    --with-protobufdir="$p" --with-pcredir="$p" \
    --without-sfcgal --without-gui --disable-nls \
    CPPFLAGS="-I$p/include" LDFLAGS="-L$p/lib" >&2 \
    || { tail -40 config.log >&2; pgext_die "postgis configure"; }
  # macOS: PostGIS's Makefiles take the bundle loader from configure's
  # bindir, not from pg_config; point it at the tree's postgres.
  if [ "$(uname -s)" = Darwin ]; then
    PGEXT_MAKE_ARGS+=("BE_DLLLIBS=-bundle_loader $("$pgc" --bindir)/postgres")
  fi
  pgext_build_pgxs "$src" "$pgc"
}

# The loaders (shp2pgsql, raster2pgsql, pgsql2shp, pgtopo_*) are client tools
# with no --version, which the bundle contract asks of a shipped program, and
# share/contrib/ holds the pre-extension install scripts; neither is needed to
# CREATE EXTENSION. The data PROJ and GDAL read at run time (PROJ_DATA,
# GDAL_DATA) goes in share/proj and share/gdal.
pgext_hook_post_collect() {
  local bundle="$1"
  rm -rf "$bundle/bin"/* "$bundle/share/contrib"
  touch "$bundle/bin/.keep"
  mkdir -p "$bundle/share/proj" "$bundle/share/gdal"
  cp -R "$POSTGIS_DEPS/share/proj/." "$bundle/share/proj/"
  cp -R "$POSTGIS_DEPS/share/gdal/." "$bundle/share/gdal/"
}
