#!/usr/bin/env bash
# recipes/pgext/lib.sh — shared machinery for Postgres extension bundles.
# Sourced by recipes/pgext/build.sh and recipes/pgext/verify.sh; not run.
#
# A bundle is one (extension, version, Postgres major, triple), packaged as
#   pgext-<name>-pg<major>-<version>-<triple>.tar.gz
# with, relative to its root:
#   bin/                 always present (pg_repack's client; else a .keep)
#   share/extension/     <name>.control + its --*.sql scripts
#   share/<data>/        data files (wave 2: PostGIS share/proj, share/gdal)
#   lib/                 the module (<name>.so on Linux; .dylib/.so on macOS,
#                        whatever PGXS/pgrx produce) and every non-system
#                        library it needs, side by side: rpath $ORIGIN /
#                        @loader_path, ad-hoc signed on macOS
#   bundle.json          name, version, pg_major, preload, settings, env,
#                        requires, license, source, recipe (written by dzb)
# The contract is doze/docs/design/postgres-extensions.md.
#
# Every bundle builds against doze-binaries' OWN Postgres tree for the major —
# the published archive of the oldest minor the catalog lists — never a
# system or Homebrew Postgres. Builds go through that tree's pg_config/PGXS.
#
# Per-extension hooks: recipes/pgext/<name>/hooks.sh, sourced when present,
# may define any of
#   pgext_hook_deps         <triple>; before the build, in the build shell:
#                           install build tools, build the versions.yaml
#                           `bundled` libraries (pgext_dep_fetch), ship
#                           their licences (pgext_dep_license) and export
#                           PGEXT_EXTRA_LIBDIRS (where relocation finds them)
#   pgext_hook_pre_build    after the source is fetched, in the source dir
#   pgext_hook_build        replaces the standard PGXS/pgrx build+install
#                           (must install into "$PGEXT_STAGE" like DESTDIR)
#   pgext_hook_post_collect after the bundle tree is assembled, before
#                           relocation (vendor extra data, drop files)
# and may set PGEXT_MAKE_ARGS (extra make arguments, an array) and, for pgrx,
# PGEXT_PGRX_FEATURES (cargo features beyond pg<major>, space-separated).
# recipes/pgext/<name>/smoke.sql is the verify step's smoke query.

# ── paths and small helpers ──────────────────────────────────────────────────
PGEXT_ROOT="${PGEXT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Downloaded Postgres trees and cargo-pgrx installs live here between builds
# (CI caches it). Never inside the repo.
PGEXT_CACHE="${PGEXT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/doze-binaries/pgext}"
# The Rust toolchain pgrx extensions build with. Pinned: a toolchain bump is a
# reviewable diff like any other input. rustup installs it on first use.
PGEXT_RUST_TOOLCHAIN="${PGEXT_RUST_TOOLCHAIN:-1.99.1}"

pgext_log() { echo "pgext: $*" >&2; }
pgext_die() { echo "pgext: ERROR: $*" >&2; exit 1; }
pgext_ncpu() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

# pgext_dzb_init builds the catalog tool once per run into a temp dir, so a
# build never depends on a stale ./dzb in the checkout. Call it before any
# $(pgext_dzb ...): a build inside a command substitution would not persist.
pgext_dzb_init() {
  [ -n "${PGEXT_DZB:-}" ] && [ -x "$PGEXT_DZB" ] && return 0
  PGEXT_DZB="$(mktemp -d)/dzb"
  (cd "$PGEXT_ROOT" && go build -o "$PGEXT_DZB" ./cmd/dzb) || pgext_die "building dzb"
  export PGEXT_DZB
}
pgext_dzb() {
  [ -n "${PGEXT_DZB:-}" ] || pgext_die "pgext_dzb_init was not called"
  (cd "$PGEXT_ROOT" && "$PGEXT_DZB" "$@")
}

pgext_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# ── build dependencies ───────────────────────────────────────────────────────
# The headers and link libraries the Postgres tree's own PGXS flags name: its
# Makefile.global carries the build host's -I/-L for ICU, OpenSSL, readline,
# lz4, zstd and libxml2, and a client program (pg_repack) links $(LIBS).
# Same package set as recipes/postgres/build.sh. PGEXT_SKIP_DEPS=1 skips it.
pgext_install_deps() {
  local triple="$1"
  [ "${PGEXT_SKIP_DEPS:-0}" = 1 ] && return 0
  case "$triple" in
    *linux*)
      sudo apt-get update -y
      sudo apt-get install -y build-essential pkg-config patchelf git curl \
        libreadline-dev zlib1g-dev libicu-dev libssl-dev liblz4-dev libzstd-dev \
        libxml2-dev uuid-dev
      # pgrx generates its Postgres bindings with bindgen, which needs libclang.
      if [ "${PGEXT_BUILD:-}" = pgrx ]; then sudo apt-get install -y libclang-dev clang; fi
      ;;
    *darwin*)
      export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
      brew install pkg-config icu4c@78 openssl@3 lz4 zstd libxml2 readline || true
      ;;
  esac
}

# pgext_toolchain_env <triple> <pgtree> exports what a compile against the
# tree needs beyond its PGXS flags, and sets PGEXT_PG_CONFIG to the pg_config
# builds must use. macOS:
#  - the tree's Makefile.global and `pg_config --cppflags` name the CI runner's
#    SDK (-isysroot /Applications/Xcode_15.4.app/...), which other machines
#    lack: PG_SYSROOT is overridden on every make, and pgrx (which reads
#    --cppflags) gets a pg_config shim that swaps in this machine's SDK;
#  - the deployment target is the tree's own (postgres's LC_BUILD_VERSION
#    minos, 14.0 today). Left alone, clang targets the BUILD host's macOS, and
#    a bundle built on a newer Mac would refuse to load on an older one;
#  - the ICU keg goes on CPATH: older trees recorded the unversioned icu4c.
pgext_toolchain_env() {
  local triple="$1" pgtree="$2"
  PGEXT_MAKE_SYS=()
  PGEXT_PG_CONFIG="$pgtree/bin/pg_config"
  case "$triple" in
    *darwin*)
      local bp sdk minos shim
      bp="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
      sdk="$(xcrun --show-sdk-path)"
      minos="$(otool -l "$pgtree/bin/postgres" | awk '/minos/ {print $2; exit}')"
      [ -n "$minos" ] || pgext_die "cannot read the deployment target of $pgtree/bin/postgres"
      export MACOSX_DEPLOYMENT_TARGET="$minos"
      PGEXT_MAKE_SYS=("PG_SYSROOT=$sdk")
      shim="$PGEXT_WORK/pg_config-shim"
      mkdir -p "$shim"
      # Paths are unaffected: the real pg_config still resolves them from its
      # own location.
      cat > "$shim/pg_config" <<SHIM
#!/usr/bin/env bash
out="\$('$pgtree/bin/pg_config' "\$@")" || exit \$?
printf '%s\n' "\$out" | sed -E 's#-isysroot [^ ]+#-isysroot $sdk#g'
SHIM
      chmod +x "$shim/pg_config"
      PGEXT_PG_CONFIG="$shim/pg_config"
      export CPATH="$bp/opt/icu4c@78/include:$bp/opt/openssl@3/include:$bp/opt/readline/include${CPATH:+:$CPATH}"
      export LIBRARY_PATH="$bp/opt/icu4c@78/lib:$bp/opt/openssl@3/lib:$bp/opt/readline/lib:$bp/opt/lz4/lib:$bp/opt/zstd/lib:$bp/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
      export SDKROOT="$sdk"
      # bindgen (pgrx) parses the server headers with libclang, which needs
      # the same include path.
      export BINDGEN_EXTRA_CLANG_ARGS="-isysroot $sdk -I$bp/opt/icu4c@78/include"
      ;;
  esac
}

# ── the Postgres tree ────────────────────────────────────────────────────────
# pgext_pg_tree <base|newest> <major> <triple>: echo the path of an extracted
# doze Postgres tree, downloading the published archive (sha256-checked) into
# the cache on first use. base = the minor bundles build against; newest = the
# minor most users run, which verify also loads every bundle into.
# PGEXT_PG_TREE_<base|newest>_<major> (a path) overrides, for local work.
pgext_pg_tree() {
  local which="$1" major="$2" triple="$3" override full url sum dir tgz
  override="PGEXT_PG_TREE_${which}_${major}"
  if [ -n "${!override:-}" ]; then echo "${!override}"; return; fi
  read -r full url sum < <(pgext_dzb pgext pgtree "$which" "$major" "$triple") \
    || pgext_die "no published postgres $which tree for $major/$triple"
  dir="$PGEXT_CACHE/pg/postgresql-$full-$triple"
  if [ ! -x "$dir/bin/pg_config" ]; then
    mkdir -p "$PGEXT_CACHE/pg"
    tgz="$PGEXT_CACHE/pg/postgresql-$full-$triple.tar.gz"
    pgext_log "downloading postgres $full ($triple)"
    curl -fsSL --retry 3 "$url" -o "$tgz" || pgext_die "download $url"
    [ "$(pgext_sha256 "$tgz")" = "$sum" ] || { rm -f "$tgz"; pgext_die "sha256 mismatch for $url"; }
    rm -rf "$dir.tmp" && mkdir -p "$dir.tmp"
    tar -C "$dir.tmp" -xzf "$tgz"
    mv "$dir.tmp/postgresql-$full-$triple" "$dir" && rm -rf "$dir.tmp" "$tgz"
  fi
  echo "$dir"
}

# ── fetch + build ────────────────────────────────────────────────────────────
pgext_fetch_source() { # <repo> <ref> <dest>
  git clone --quiet --depth 1 --branch "$2" -c advice.detachedHead=false "$1" "$3" \
    || pgext_die "git clone $1 @ $2"
}

# pgext_build_pgxs: the standard `make && make install DESTDIR=` against the
# tree's pg_config. USE_PGXS=1 because several extensions (pgaudit,
# pg_hint_plan) only take the PGXS path when it is set.
pgext_build_pgxs() {
  local src="$1" pgc="$2"
  local args=(PG_CONFIG="$pgc" USE_PGXS=1 "${PGEXT_MAKE_SYS[@]}" ${PGEXT_MAKE_ARGS[@]+"${PGEXT_MAKE_ARGS[@]}"})
  make -C "$src" -j"$(pgext_ncpu)" "${args[@]}"
  make -C "$src" "${args[@]}" install DESTDIR="$PGEXT_STAGE"
}

# pgext_cargo_pgrx <src>: echo a cargo-pgrx whose version matches the crate's
# own locked pgrx (a mismatch refuses to build), installing it into the cache
# on first use. Keyed by Rust toolchain too: cargo-pgrx is a compiled tool.
pgext_cargo_pgrx() {
  local src="$1" lock ver dir
  # The crate's own lock, or its workspace's (pg_search sits in a subdir).
  lock="$src"
  while [ ! -f "$lock/Cargo.lock" ] && [ "$lock" != "$PGEXT_WORK" ] && [ "$lock" != / ]; do
    lock="$(dirname "$lock")"
  done
  lock="$lock/Cargo.lock"
  if [ -f "$lock" ]; then
    ver="$(awk '/^name = "pgrx"$/ {getline; gsub(/[^0-9.a-z-]/, "", $3); print $3; exit}' "$lock")"
  else
    # No lock committed upstream (pgvectorscale): the crate must then pin pgrx
    # exactly (pgrx = "=0.16.1"), or the build is refused.
    lock="$src/Cargo.toml"
    ver="$(sed -nE 's/^pgrx[[:space:]]*=[[:space:]]*\{?[^"]*"=([0-9][0-9.a-z-]*)".*/\1/p' "$lock" | head -1)"
  fi
  [ -n "$ver" ] || pgext_die "no exact pgrx version in $lock (a pgrx build needs a Cargo.lock or pgrx = \"=x.y.z\")"
  dir="$PGEXT_CACHE/pgrx/$ver-rust$PGEXT_RUST_TOOLCHAIN"
  if [ ! -x "$dir/bin/cargo-pgrx" ]; then
    pgext_log "installing cargo-pgrx $ver (rust $PGEXT_RUST_TOOLCHAIN)"
    cargo "+$PGEXT_RUST_TOOLCHAIN" install cargo-pgrx --version "$ver" --locked --root "$dir" >&2 \
      || pgext_die "cargo install cargo-pgrx $ver"
  fi
  echo "$dir/bin"
}

# pgext_ensure_rust: rustup is the one Rust prerequisite; the pinned toolchain
# is installed on first use (minimal profile — rustc, cargo, rust-std).
pgext_ensure_rust() {
  if ! command -v rustup >/dev/null; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none >&2
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  rustup toolchain list | grep -q "^$PGEXT_RUST_TOOLCHAIN" \
    || rustup toolchain install "$PGEXT_RUST_TOOLCHAIN" --profile minimal >&2
}

# pgext_build_pgrx: `cargo pgrx package` against the tree's pg_config, with
# only the pg<major> feature, into "$PGEXT_STAGE" (same absolute layout as a
# DESTDIR install). PGRX_HOME is private to the build so nothing leaks into
# ~/.pgrx, and `cargo pgrx init` is pointed at our tree (no download).
pgext_build_pgrx() {
  local src="$1" pgc="$2" major="$3" bin
  pgext_ensure_rust
  bin="$(pgext_cargo_pgrx "$src")"
  export PATH="$bin:$PATH" RUSTUP_TOOLCHAIN="$PGEXT_RUST_TOOLCHAIN"
  export PGRX_HOME="$PGEXT_WORK/pgrx-home"
  export CARGO_TARGET_DIR="${PGEXT_CARGO_TARGET_DIR:-$PGEXT_WORK/target}"
  mkdir -p "$PGRX_HOME"
  (cd "$src" && cargo pgrx init "--pg$major" "$pgc" >&2)
  (cd "$src" && cargo pgrx package --pg-config "$pgc" --no-default-features \
      --features "pg$major${PGEXT_PGRX_FEATURES:+ $PGEXT_PGRX_FEATURES}" --out-dir "$PGEXT_STAGE" >&2)
}

# ── collect into the contract layout ─────────────────────────────────────────
# pgext_collect <pgc> <bundle>: map what the install wrote under $PGEXT_STAGE
# (the tree's absolute paths, DESTDIR-style) onto the bundle layout. Headers
# and docs are build-time only and dropped; anything else unexpected fails the
# build rather than shipping somewhere the module never looks.
pgext_collect() {
  local pgc="$1" bundle="$2" share lib bindir inc doc s
  share="$PGEXT_STAGE$("$pgc" --sharedir)"
  lib="$PGEXT_STAGE$("$pgc" --pkglibdir)"
  bindir="$PGEXT_STAGE$("$pgc" --bindir)"
  inc="$PGEXT_STAGE$("$pgc" --includedir)"
  doc="$PGEXT_STAGE$("$pgc" --docdir)"
  mkdir -p "$bundle/bin" "$bundle/lib" "$bundle/share"
  [ -d "$share/extension" ] || pgext_die "the install wrote no share/extension (control file)"
  [ -d "$bindir" ] && cp -R "$bindir/." "$bundle/bin/" && rm -rf "$bindir"
  # pkglibdir == libdir in doze trees; LLVM bitcode is never built (no LLVM).
  [ -d "$lib" ] && cp -R "$lib/." "$bundle/lib/" && rm -rf "$lib"
  rm -rf "$bundle/lib/bitcode"
  rm -rf "$doc" "$inc"
  cp -R "$share/." "$bundle/share/" && rm -rf "$share"
  rm -rf "$bundle/share/doc"
  # Whatever remains under the stage was installed somewhere we don't ship.
  s="$(find "$PGEXT_STAGE" -type f | head -5)"
  [ -z "$s" ] || pgext_die "install wrote files outside bin/lib/share: $s"
  [ -n "$(ls -A "$bundle/bin")" ] || touch "$bundle/bin/.keep"
}

# ── relocation ───────────────────────────────────────────────────────────────
# Every non-system library a shipped binary needs is copied into the bundle's
# lib/, beside the module, and referenced relative to the referrer:
#   lib/*  -> @loader_path/<lib>          (Linux rpath $ORIGIN)
#   bin/*  -> @loader_path/../lib/<lib>   (Linux rpath $ORIGIN/../lib)
# That includes libraries the Postgres tree itself ships (libpq, libssl…):
# from PG18 doze installs bundles into their own folder, outside the tree, so
# the bundle must stand alone. An installer copying into a PG14-17 tree must
# not overwrite the tree's own copy of such a library (same major, newer
# minor); @loader_path/<lib> then resolves to the tree's.

pgext_is_system_linux() {
  case "$1" in
    libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|ld-linux*|linux-vdso*|\
    libgcc_s.so*|libstdc++.so*|libresolv.so*|libutil.so*) return 0 ;;
  esac
  return 1
}

pgext_relocate_linux() {
  local bundle="$1" pgtree="$2" f name path rp
  command -v patchelf >/dev/null || pgext_die "patchelf is required"
  for _ in 1 2 3; do  # three passes: transitive deps of vendored libs
    while IFS= read -r f; do
      file -b "$f" | grep -q ELF || continue
      while read -r name path; do
        pgext_is_system_linux "$name" && continue
        [ "$path" = "not" ] && pgext_die "$(basename "$f"): $name not found"
        [ -e "$bundle/lib/$name" ] && continue
        pgext_log "vendoring $name (from $path)"
        echo "$name $path" >> "$PGEXT_WORK/vendored.txt"
        cp -L "$path" "$bundle/lib/$name" && chmod u+w "$bundle/lib/$name"
      done < <(LD_LIBRARY_PATH="$bundle/lib:$pgtree/lib${PGEXT_EXTRA_LIBDIRS:+:$PGEXT_EXTRA_LIBDIRS}" ldd "$f" 2>/dev/null | awk '/=>/ {print $1" "$3}')
    done < <(find "$bundle/bin" "$bundle/lib" -type f)
  done
  # Strip before patchelf (see scripts/bundle-linux-deps.sh for why).
  while IFS= read -r f; do
    file -b "$f" | grep -q ELF || continue
    strip --strip-debug "$f" 2>/dev/null || true
    case "$f" in "$bundle/bin/"*) rp="\$ORIGIN/../lib" ;; *) rp="\$ORIGIN" ;; esac
    patchelf --set-rpath "$rp" "$f"
  done < <(find "$bundle/bin" "$bundle/lib" -type f)
}

pgext_is_system_macos() { case "$1" in /usr/lib/*|/System/*) return 0 ;; esac; return 1; }

# pgext_macho_fix <file> <origin_dir> <bundle> <pgtree>: rewrite every
# non-system reference of one Mach-O to the bundle-relative form, vendoring
# the referenced library on the way (recursively). origin_dir is where the
# file's own @loader_path refs resolve — its ORIGINAL home for a library
# just copied in from the Postgres tree or Homebrew.
pgext_macho_fix() {
  local f="$1" origin="$2" bundle="$3" pgtree="$4" self dep base src prefix bp
  bp="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  case "$f" in "$bundle/bin/"*) prefix="@loader_path/../lib/" ;; *) prefix="@loader_path/" ;; esac
  self="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1)"
  while read -r dep; do
    [ -n "$dep" ] && [ "$dep" != "$self" ] || continue
    pgext_is_system_macos "$dep" && continue
    base="$(basename "$dep")"
    src=""
    case "$dep" in
      @loader_path/*|@executable_path/*) src="$origin/${dep#@*/}" ;;
      /*) src="$dep" ;;
    esac
    if [ -z "$src" ] || [ ! -e "$src" ]; then
      local d
      local -a extra=()
      [ -z "${PGEXT_EXTRA_LIBDIRS:-}" ] || IFS=: read -r -a extra <<< "$PGEXT_EXTRA_LIBDIRS"
      for d in "$bundle/lib" "$pgtree/lib" "$origin" ${extra[@]+"${extra[@]}"} "$bp/lib"; do
        [ -e "$d/$base" ] && { src="$d/$base"; break; }
      done
    fi
    [ -n "$src" ] && [ -e "$src" ] || pgext_die "$(basename "$f"): cannot find $dep"
    if [ ! -e "$bundle/lib/$base" ]; then
      pgext_log "vendoring $base (from $src)"
      echo "$base $src" >> "$PGEXT_WORK/vendored.txt"
      cp -L "$src" "$bundle/lib/$base" && chmod u+w "$bundle/lib/$base"
      install_name_tool -id "@rpath/$base" "$bundle/lib/$base" 2>/dev/null || true
      pgext_macho_fix "$bundle/lib/$base" "$(dirname "$src")" "$bundle" "$pgtree"
    fi
    install_name_tool -change "$dep" "$prefix$base" "$f" 2>/dev/null
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
}

pgext_relocate_macos() {
  local bundle="$1" pgtree="$2" f
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    pgext_macho_fix "$f" "$(dirname "$f")" "$bundle" "$pgtree"
  done < <(find "$bundle/bin" "$bundle/lib" -type f)
  # Ad-hoc sign everything (required on Apple Silicon after any rewrite).
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    codesign --force --sign - "$f" 2>/dev/null || pgext_die "codesign $f"
  done < <(find "$bundle/bin" "$bundle/lib" -type f)
}

# ── bundled third-party libraries and licences ───────────────────────────────
# A bundle carries its own licence and the licence of every library built
# into it, under share/licenses/<name>/: the extension's from its source root,
# and each versions.yaml `bundled` library's from its source, put there by the
# recipe's hooks with pgext_dep_license. The build fails when one is missing.
# share/licenses/<name>/vendored-libraries.txt lists every library the
# relocation step copied in, and where from.

# pgext_dep_fetch <dep> <dest>: download the dep's pinned tarball (versions.yaml
# bundled: source + sha256) into the cache, check it, and unpack it into a new
# <dest>; echo the unpacked source directory.
pgext_dep_fetch() {
  local dep="$1" dest="$2" v url sum tgz top
  v="PGEXT_DEP_$(echo "$dep" | tr 'a-z-' 'A-Z_')"
  url="$(eval echo "\${${v}_URL:-}")"; sum="$(eval echo "\${${v}_SHA256:-}")"
  [ -n "$url" ] && [ -n "$sum" ] || pgext_die "$dep is not a bundled tarball in versions.yaml"
  mkdir -p "$PGEXT_CACHE/src"
  tgz="$PGEXT_CACHE/src/$sum-$(basename "$url")"
  if [ ! -f "$tgz" ]; then
    pgext_log "downloading $dep ($url)"
    curl -fsSL --retry 3 "$url" -o "$tgz.part" || pgext_die "download $url"
    mv "$tgz.part" "$tgz"
  fi
  [ "$(pgext_sha256 "$tgz")" = "$sum" ] || { rm -f "$tgz"; pgext_die "sha256 mismatch for $url"; }
  rm -rf "$dest" && mkdir -p "$dest"
  tar -C "$dest" -xf "$tgz"
  top="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$top" ] || pgext_die "$dep: empty tarball"
  echo "$top"
}

# pgext_dep_license <dep> <file>...: ship these licence files for a bundled
# library (or for the extension itself) as share/licenses/<dep>/.
pgext_dep_license() {
  local dep="$1" f; shift
  mkdir -p "$PGEXT_WORK/licenses/$dep"
  for f in "$@"; do
    [ -f "$f" ] || pgext_die "$dep: licence file $f does not exist"
    cp "$f" "$PGEXT_WORK/licenses/$dep/"
  done
}

# pgext_own_license <src_root>: the extension's licence files from the top of
# its source checkout (and the subdir it builds in, if any).
pgext_own_license() {
  local dir f found=0
  for dir in "$@"; do
    for f in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING* "$dir"/COPYRIGHT* "$dir"/NOTICE*; do
      [ -f "$f" ] || continue
      pgext_dep_license "$PGEXT_NAME" "$f"; found=1
    done
  done
  [ "$found" = 1 ] || pgext_die "no LICENSE/COPYING file at the top of the $PGEXT_NAME source"
}

# pgext_place_licenses <bundle>: move the collected licences into the bundle
# and fail if the extension's own or any bundled library's is missing.
pgext_place_licenses() {
  local bundle="$1" d
  mkdir -p "$bundle/share/licenses"
  cp -R "$PGEXT_WORK/licenses/." "$bundle/share/licenses/"
  for d in "$PGEXT_NAME" $PGEXT_BUNDLED; do
    [ -n "$(ls -A "$bundle/share/licenses/$d" 2>/dev/null)" ] \
      || pgext_die "share/licenses/$d is empty: every bundled library ships its licence (pgext_dep_license)"
  done
  if [ -f "$PGEXT_WORK/vendored.txt" ]; then
    sed -e "s#$PGEXT_WORK#<build>#g" -e "s#$HOME#~#g" "$PGEXT_WORK/vendored.txt" \
      > "$bundle/share/licenses/$PGEXT_NAME/vendored-libraries.txt"
  fi
}

# ── the whole build ──────────────────────────────────────────────────────────
# pgext_build <name> <version> <pg_major> <triple> <out>
pgext_build() {
  local name="$1" version="$2" major="$3" triple="$4" out="$5"
  local env pgtree pgc src bundle base t0
  t0="$(date +%s)"
  mkdir -p "$out"; out="$(cd "$out" && pwd)"
  pgext_dzb_init
  env="$(pgext_dzb pgext env "$name" "$version" "$major")" || pgext_die "not in the catalog"
  eval "$env"
  pgext_install_deps "$triple"
  PGEXT_WORK="$(mktemp -d)"
  PGEXT_STAGE="$PGEXT_WORK/stage"
  export PGEXT_WORK PGEXT_STAGE
  pgtree="$(pgext_pg_tree base "$major" "$triple")"
  pgext_toolchain_env "$triple" "$pgtree"
  pgc="$PGEXT_PG_CONFIG"
  "$pgc" --version | grep -q "PostgreSQL $major\." || pgext_die "$pgc is not Postgres $major"
  pgext_log "building $PGEXT_ENGINE $version ($PGEXT_REF) against $("$pgc" --version) for $triple"

  src="$PGEXT_WORK/src"
  pgext_fetch_source "$PGEXT_REPO" "$PGEXT_REF" "$src"
  [ -z "$PGEXT_SUBDIR" ] || src="$src/$PGEXT_SUBDIR"
  pgext_own_license "$PGEXT_WORK/src" ${PGEXT_SUBDIR:+"$src"}
  PGEXT_MAKE_ARGS=()
  local hooks="$PGEXT_ROOT/recipes/pgext/$name/hooks.sh"
  # shellcheck disable=SC1090
  [ -f "$hooks" ] && . "$hooks"
  # Bundled libraries are built here, in this shell, so what the hook exports
  # (PGEXT_EXTRA_LIBDIRS, CPATH, PKG_CONFIG_PATH …) reaches the build and the
  # relocation step.
  if declare -F pgext_hook_deps >/dev/null; then pgext_hook_deps "$triple"; fi
  if declare -F pgext_hook_pre_build >/dev/null; then (cd "$src" && pgext_hook_pre_build); fi
  mkdir -p "$PGEXT_STAGE"
  if declare -F pgext_hook_build >/dev/null; then
    (cd "$src" && pgext_hook_build "$src" "$pgc" "$major")
  else
    case "$PGEXT_BUILD" in
      pgxs) pgext_build_pgxs "$src" "$pgc" ;;
      pgrx) pgext_build_pgrx "$src" "$pgc" "$major" ;;
    esac
  fi

  base="$PGEXT_ENGINE-$version-$triple"
  bundle="$PGEXT_WORK/$base"
  pgext_collect "$pgc" "$bundle"
  [ -f "$bundle/share/extension/$name.control" ] \
    || pgext_die "no share/extension/$name.control — is '$name' the CREATE EXTENSION name?"
  if declare -F pgext_hook_post_collect >/dev/null; then pgext_hook_post_collect "$bundle"; fi
  case "$triple" in
    *linux*)  pgext_relocate_linux "$bundle" "$pgtree" ;;
    *darwin*) pgext_relocate_macos "$bundle" "$pgtree" ;;
  esac
  pgext_place_licenses "$bundle"
  pgext_dzb pgext bundle-json "$name" "$version" "$major" > "$bundle/bundle.json"

  "$PGEXT_ROOT/scripts/package.sh" "$bundle" "$base" "$out"
  pgext_log "built $base in $(( $(date +%s) - t0 ))s ($(du -h "$out/$base.tar.gz" | awk '{print $1}'))"
  [ "${PGEXT_KEEP_WORK:-0}" = 1 ] || { chmod -R u+w "$PGEXT_WORK" 2>/dev/null; rm -rf "$PGEXT_WORK"; }
}
