#!/usr/bin/env bash
# recipes/mariadb/build.sh <version> <ref> <triple> <out_dir>
#   version   e.g. 11.4.5
#   ref       e.g. mariadb-11.4.5   (the upstream release directory name)
#
# MariaDB ships prebuilt "generic" binary tarballs, so — unlike the from-source
# engines — this recipe REPACKAGES the upstream tarball rather than compiling: it
# downloads the tarball for the triple, extracts just the binaries doze needs
# (mariadbd + the client/admin/install tools) plus their required share/ (error
# messages, charsets) and lib/ (storage-engine + auth plugins), relocates bundled
# libraries, then packages + smoke-tests like every other engine.
#
# VALIDATION NEEDED (see doze-binaries README): confirm upstream publishes a
# native aarch64-apple-darwin generic tarball for the pinned version. If it does
# not, switch the darwin arm to a Homebrew-bottle extraction or a CMake source
# build — the rest of the recipe (extract → relocate → package → smoke) is
# unchanged.
set -euo pipefail

version="$1"; ref="$2"; triple="$3"; out="${4:-dist}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$(mktemp -d)/mariadb"; mkdir -p "$prefix/bin" "$prefix/share" "$prefix/lib"

# Map the doze triple to MariaDB's generic-tarball platform token.
case "$triple" in
  x86_64-*linux*)   plat="linux-systemd-x86_64" ;;
  aarch64-*linux*)  plat="linux-systemd-aarch64" ;;
  aarch64-*darwin*) plat="macos-arm64" ;;   # VALIDATE: upstream availability
  x86_64-*darwin*)  plat="macos-x86_64" ;;
  *) echo "unknown triple: $triple" >&2; exit 1 ;;
esac

base="mariadb-${version}-${plat}"
url="https://archive.mariadb.org/${ref}/bintar-${plat}/${base}.tar.gz"

work="$(mktemp -d)"; cd "$work"
echo "fetching $url"
curl -fsSL "$url" -o mariadb.tar.gz
tar -xzf mariadb.tar.gz
src="$(find "$work" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[ -n "$src" ] || { echo "no extracted dir from $base" >&2; exit 1; }

# The binaries doze actually launches (server + client + admin + system-table
# initializer). Newer MariaDB names them mariadb*; older ship mysql* aliases.
for b in mariadbd mariadb mariadb-admin mariadb-install-db; do
  if [ -x "$src/bin/$b" ]; then
    cp -p "$src/bin/$b" "$prefix/bin/$b"
  elif [ -x "$src/sbin/$b" ]; then
    cp -p "$src/sbin/$b" "$prefix/bin/$b"
  elif [ -x "$src/scripts/$b" ]; then
    # mariadb-install-db is a shell script shipped under scripts/ in the
    # generic tarballs; it takes --basedir so it relocates fine.
    cp -p "$src/scripts/$b" "$prefix/bin/$b"
  else
    echo "warning: $b not found in upstream tarball" >&2
  fi
done

# Runtime support data: mariadbd loads error messages + charsets by relative
# path, and mariadb-install-db bootstraps the system tables from the SQL files
# in share/ (mysql_system_tables.sql and friends). Ship the whole share/ tree —
# it is plain data, relocation-safe, and cherry-picking it is how the first
# release attempt broke.
cp -R "$src/share/." "$prefix/share/" 2>/dev/null || true

# Helper tools mariadb-install-db shells out to.
for b in my_print_defaults resolveip; do
  [ -x "$src/bin/$b" ] && cp -p "$src/bin/$b" "$prefix/bin/$b" || true
done
[ -d "$src/lib/plugin" ] && cp -R "$src/lib/plugin" "$prefix/lib/" || true

# Drop optional plugins that link system libraries doze never ships — they trip
# the relocation gate and serve no doze use case: OQGraph (libJudy), cracklib
# password strength (libcrack).
rm -f "$prefix/lib/plugin/ha_oqgraph.so" "$prefix/lib/plugin/cracklib_password_check.so"

# Relocate any bundled dylibs/so so nothing points at the build/extract path.
"$root/scripts/bundle-macos-deps.sh" "$prefix" 2>/dev/null || true
"$root/scripts/bundle-linux-deps.sh" "$prefix" 2>/dev/null || true

"$root/scripts/package.sh" "$prefix" "mariadb-$version-$triple" "$out"
"$root/scripts/smoke.sh" mariadb "$out/mariadb-$version-$triple.tar.gz" "$triple"
