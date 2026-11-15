#!/usr/bin/env bash
# recipes/pgext/build.sh <name> <version> <pg_major> <triple> <out_dir>
#   name      the extension's CREATE EXTENSION name (vector, pg_cron, …)
#   version   the extension's own version, as catalogued (0.8.7)
#   pg_major  14 … 18
#
# Builds one Postgres extension bundle against doze's own Postgres tree for
# that major, packages pgext-<name>-pg<major>-<version>-<triple>.tar.gz into
# <out_dir>, then verifies it (scripts/smoke.sh -> recipes/pgext/verify.sh):
# installed into the tree, preloaded if it must be, CREATE EXTENSION, smoke
# query. Everything about the extension comes from versions.yaml via dzb; the
# machinery is in lib.sh.
#
# Local knobs: PGEXT_SKIP_DEPS=1 (no apt/brew), PGEXT_KEEP_WORK=1 (keep the
# build dir), PGEXT_PG_TREE_base_<major>=<path> (use a local Postgres tree),
# PGEXT_SKIP_VERIFY=1 (package only).
set -euo pipefail
[ $# -eq 5 ] || { echo "usage: $0 <name> <version> <pg_major> <triple> <out_dir>" >&2; exit 2; }

# shellcheck source=recipes/pgext/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

name="$1"; version="$2"; major="$3"; triple="$4"; out="$5"
pgext_build "$name" "$version" "$major" "$triple" "$out"

[ "${PGEXT_SKIP_VERIFY:-0}" = 1 ] && exit 0
out="$(cd "$out" && pwd)"
"$PGEXT_ROOT/scripts/smoke.sh" "pgext-$name-pg$major" \
  "$out/pgext-$name-pg$major-$version-$triple.tar.gz" "$triple"
