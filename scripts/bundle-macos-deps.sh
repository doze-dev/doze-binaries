#!/usr/bin/env bash
# bundle-macos-deps.sh <install_dir> <brew_prefix>
#
# Make a macOS build relocatable: copy every non-system dylib the binaries link
# into <install_dir>/lib, rewrite every install name to @loader_path/../lib/<real
# filename>, and ad-hoc codesign. Adapted from theseus-rs/postgresql-binaries (MIT).
#
# Why this is more than a one-liner: a dependency is *referenced* by the name its
# producer advertised (often a major-version symlink, e.g. libicuuc.78.dylib) but
# the file on disk is the fully-versioned real file (libicuuc.78.3.dylib). We must
# copy the real file AND rewrite references to that real filename — not the symlink
# name — or dyld looks for a file that isn't there. We must also follow *every*
# non-system dependency, including @loader_path/@rpath-relative ones (ICU's
# libicui18n → libicuuc → libicudata chain is wired this way), not just the ones
# that happen to live under the Homebrew prefix.
#
# No pipefail: some otool pipelines below legitimately match nothing.
set -eu

INSTALL_DIR="$1"
BREW_PREFIX="${2:-}"
[ -n "$INSTALL_DIR" ] || { echo "usage: $0 <install_dir> [brew_prefix]"; exit 1; }
# pwd -P resolves symlinks so INSTALL_DIR matches the canonical paths realpath_of
# returns (macOS /tmp -> /private/tmp, /var -> /private/var); otherwise the
# "already inside the tree" prefix test fails and in-tree extension libs under
# lib/postgresql/ get wrongly re-bundled (flattened) into lib/.
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
mkdir -p "$INSTALL_DIR/lib"

realpath_of() { python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }

# loader_prefix echoes the @loader_path-relative prefix that reaches
# <install_dir>/lib from the directory holding the Mach-O passed as $1. A file in
# bin/ or lib/ is one level under the tree root, so "../lib/"; an extension in
# lib/postgresql/ is two, so "../../lib/". Computed from depth so any nesting
# works — needed now that we rewrite the extension dylibs under lib/postgresql/.
loader_prefix() {
  local dir rel ups part
  dir="$(cd "$1" && pwd)"
  rel="${dir#"$INSTALL_DIR"/}"
  ups=""
  local IFS=/
  for part in $rel; do ups="../$ups"; done
  echo "@loader_path/${ups}lib/"
}

is_system() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve a (possibly @loader_path/@rpath/relative) dependency reference, recorded
# in a file living at <origin_dir>, to an absolute real path on disk.
resolve_dep() {
  local ref="$1" origin_dir="$2" cand="" base
  base="$(basename "$ref")"
  case "$ref" in
    @loader_path/*|@executable_path/*) cand="$origin_dir/${ref#@*/}" ;;
    @rpath/*)                          cand="" ;;   # resolved by the tree search below
    /*)                                cand="$ref" ;;
    *)                                 cand="$origin_dir/$ref" ;;
  esac
  # If the candidate isn't a real file — a @rpath ref, or an absolute reference
  # into a build prefix that no longer exists (an extension dylib that recorded
  # $TMP/.../lib/libpq.5.dylib, or a documentdb lib re-exporting a sibling by its
  # build-time install_name) — recover by basename. Search the tree FIRST, and
  # lib/postgresql/ before lib/ so a sibling extension (e.g. pg_documentdb_core)
  # resolves to its real home and is never duplicated into lib/.
  if [ -z "$cand" ] || [ ! -e "$cand" ]; then
    local d
    for d in "$INSTALL_DIR/lib/postgresql" "$INSTALL_DIR/lib" "$origin_dir" "$BREW_PREFIX/lib"; do
      [ -n "$d" ] && [ -e "$d/$base" ] && { cand="$d/$base"; break; }
    done
    cand="${cand:-$BREW_PREFIX/lib/$base}"
  fi
  realpath_of "$cand"
}

# Rewrite every external/internal dependency of an already-placed Mach-O file to
# @loader_path/../lib/<real filename>, bundling externals on the way. Progress is
# routed to stderr so the function's stdout stays clean for callers that capture it.
#
# <origin> is the directory @loader_path/@rpath references should resolve against.
# For a file we just copied out of Homebrew it must be the *original* source dir
# (so ICU's @loader_path/libicudata still points at the real file to copy), not
# the copy's new home — hence the explicit second argument.
rewrite() {
  local file="$1" origin="${2:-}" self dep resolved sub prefix
  file "$file" | grep -q "Mach-O" || return 0
  self="$(realpath_of "$file")"
  [ -n "$origin" ] || origin="$(dirname "$file")"
  # Prefix that reaches the tree's lib/ from THIS file's directory (bin/, lib/, or
  # lib/postgresql/ all differ in depth).
  prefix="$(loader_prefix "$(dirname "$file")")"
  # Skip the first otool line (the file header); the lib's own id is filtered by
  # the self-comparison below.
  while read -r dep; do
    [ -n "$dep" ] || continue
    is_system "$dep" && continue
    resolved="$(resolve_dep "$dep" "$origin")"
    [ "$resolved" = "$self" ] && continue          # the file's own id
    case "$resolved" in
      "$INSTALL_DIR"/lib/*) sub="${resolved#"$INSTALL_DIR"/lib/}" ;; # already in tree (lib/ or lib/postgresql/)
      "$INSTALL_DIR"/*)     continue ;;                              # in-tree but not a lib — leave alone
      *)                    sub="$(bundle "$resolved")" ;;           # external → copy into lib/
    esac
    [ -n "$sub" ] || continue
    # @loader_path/<ups>lib/<sub>: <sub> keeps the postgresql/ segment for sibling
    # extension references so they resolve to lib/postgresql/, not lib/.
    install_name_tool -change "$dep" "${prefix}${sub}" "$file" 2>/dev/null || true
  done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
}

# Ensure an external dylib is copied into lib/ under its real filename, recurse
# into its own dependencies, and echo the real filename for the caller's -change.
bundle() {
  local src="$1" real name
  real="$(realpath_of "$src")"
  name="$(basename "$real")"
  if [ ! -f "$INSTALL_DIR/lib/$name" ]; then
    echo "  bundling $name" >&2
    cp "$real" "$INSTALL_DIR/lib/$name"
    chmod +w "$INSTALL_DIR/lib/$name"
    install_name_tool -id "@loader_path/../lib/$name" "$INSTALL_DIR/lib/$name" 2>/dev/null || true
    # Resolve this copy's @loader_path refs against its ORIGINAL directory.
    rewrite "$INSTALL_DIR/lib/$name" "$(dirname "$real")"
  fi
  echo "$name"
}

# Roots: every Mach-O in bin/ and every real (non-symlink) dylib OR .so bundle
# anywhere under lib/ — postgres extension modules are .so Mach-O bundles
# (dblink.so, postgres_fdw.so, …) whose build-time references to libpq must be
# relocated too. A dylib-only walk here shipped 14.x/15.x extensions with an
# absolute build-tmp libpq path that only the deep smoke finally caught.
while IFS= read -r b; do rewrite "$b"; done < <(find "$INSTALL_DIR/bin" -type f 2>/dev/null)
while IFS= read -r l; do
  [ -L "$l" ] && continue
  rewrite "$l"
  # Strip the build-prefix install id (LC_ID_DYLIB). Every real reference is
  # already rewritten to a @loader_path path, so the id is otherwise unused — but
  # leaving the build-tmp path in it ships a dangling absolute path and trips the
  # smoke relocation check. @rpath/<name> is the conventional relocatable id.
  # (.so bundles carry no id; install_name_tool errors and the || true skips.)
  install_name_tool -id "@rpath/$(basename "$l")" "$l" 2>/dev/null || true
done < <(find "$INSTALL_DIR/lib" \( -name "*.dylib" -o -name "*.so" \) 2>/dev/null)

# Ad-hoc sign everything we touched (required on Apple Silicon).
find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if file "$f" | grep -q "Mach-O"; then
    chmod +w "$f"; codesign --force --sign - "$f" 2>/dev/null || true
  fi
done

echo "bundled macOS deps into $INSTALL_DIR/lib"
