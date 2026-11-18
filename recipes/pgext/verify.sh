#!/usr/bin/env bash
# recipes/pgext/verify.sh <archive> <triple>
#
# The publish gate for an extension bundle (scripts/smoke.sh hands pgext-*
# archives here, after its relocation check). For the Postgres tree the bundle
# was built against (the major's oldest minor) AND the newest minor:
#   1. install the bundle the way doze will: PG14-17 by copying into a
#      throwaway copy of the tree without overwriting anything the tree ships;
#      PG18+ in a folder of its own joined through extension_control_path and
#      dynamic_library_path, nothing written into the tree;
#   2. initdb, apply bundle.json's preload + settings ({db} = postgres), start;
#   3. CREATE EXTENSION each of `requires`, then the extension (CASCADE), then
#      every name it `provides` (CASCADE);
#   4. run recipes/pgext/<name>/smoke.sql (and smoke.sh, for a client binary).
# A bundle that needs another bundle (pgrouting needs postgis; h3_postgis
# needs postgis) is verified with that bundle installed beside it, the same
# way: the dependency archive is taken from PGEXT_DEPS_DIR or the archive's
# own folder, else downloaded from its published release.
# Also checks share/licenses/: the extension's licence and every bundled
# library's (versions.yaml `bundled`).
# Also checks the archive against the contract: bundle.json fields, name and
# version matching the archive name, share/extension/<name>.control, bin/.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <archive> <triple>" >&2; exit 2; }

# shellcheck source=recipes/pgext/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
pgext_dzb_init

archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; triple="$2"
work="$(mktemp -d)"
cleanup() {
  local d
  for d in "$work"/data-*; do
    [ -d "$d" ] && "$work/pg-${d##*/data-}/bin/pg_ctl" -D "$d" stop -m immediate >/dev/null 2>&1 || true
  done
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

tar -C "$work" -xzf "$archive"
top="$(basename "$archive" .tar.gz)"
bundle="$work/$top"
[ -d "$bundle" ] || pgext_die "archive's top directory is not $top"
[ -d "$bundle/bin" ] || pgext_die "no bin/ (the contract requires it, with a .keep if empty)"
[ -f "$bundle/bundle.json" ] || pgext_die "no bundle.json"

# Contract-check bundle.json (dzb) and read it. {root} is filled per install.
eval "$(pgext_dzb pgext-bundle "$bundle/bundle.json" postgres '{root}')"
want="pgext-$BUNDLE_NAME-pg$BUNDLE_PG_MAJOR-$BUNDLE_VERSION-$triple"
[ "$top" = "$want" ] || pgext_die "archive is $top but bundle.json says $want"
[ -f "$bundle/share/extension/$BUNDLE_NAME.control" ] || pgext_die "no share/extension/$BUNDLE_NAME.control"
echo "  verify: $BUNDLE_NAME $BUNDLE_VERSION for PG$BUNDLE_PG_MAJOR (preload: ${BUNDLE_PRELOAD:-none})"

for d in "$BUNDLE_NAME" $(pgext_dzb pgext bundled "$BUNDLE_NAME"); do
  [ -n "$(ls -A "$bundle/share/licenses/$d" 2>/dev/null)" ] \
    || pgext_die "no share/licenses/$d: the bundle must carry its own licence and every bundled library's"
done
PROVIDES="$(pgext_dzb pgext provides "$BUNDLE_NAME" | tr '\n' ' ')"

# The bundles this one needs, dependencies first, unpacked under $work/deps.
deps=()
deplist="$(pgext_dzb pgext deps "$BUNDLE_NAME" "$BUNDLE_PG_MAJOR")" || pgext_die "resolving the bundles $BUNDLE_NAME needs"
while read -r dname dver; do
  [ -n "$dname" ] || continue
  dtop="pgext-$dname-pg$BUNDLE_PG_MAJOR-$dver-$triple"
  found=""
  for dir in ${PGEXT_DEPS_DIR:-} "$(dirname "$archive")"; do
    [ -f "$dir/$dtop.tar.gz" ] && { found="$dir/$dtop.tar.gz"; break; }
  done
  if [ -z "$found" ]; then
    if read -r durl dsum < <(pgext_dzb pgext artifact "$dname" "$BUNDLE_PG_MAJOR" "$dver" "$triple"); then
      found="$work/$dtop.tar.gz"
      curl -fsSL --retry 3 "$durl" -o "$found" || pgext_die "download $durl"
      [ "$(pgext_sha256 "$found")" = "$dsum" ] || pgext_die "sha256 mismatch for $durl"
    else
      pgext_die "$BUNDLE_NAME needs $dtop: not in ${PGEXT_DEPS_DIR:-the folder of the archive} and not published (build it first)"
    fi
  fi
  mkdir -p "$work/deps"
  tar -C "$work/deps" -xzf "$found"
  [ -f "$work/deps/$dtop/bundle.json" ] || pgext_die "$found has no $dtop/bundle.json"
  echo "  verify: with $dtop"
  deps+=("$dtop")
done <<< "$deplist"

recipe_dir="$PGEXT_ROOT/recipes/pgext/$BUNDLE_NAME"

# copy_missing <from> <to>: copy every file the destination lacks (cp -n's
# exit status differs between GNU and BSD cp, so it can't be trusted under -e).
# A file the tree already has is reported, not replaced.
copy_missing() {
  local f rel
  while IFS= read -r f; do
    rel="${f#"$1"/}"
    [ "$rel" = .keep ] && continue
    if [ -e "$2/$rel" ]; then
      echo "  verify: kept the tree's own $(basename "$2")/$rel"
    else
      mkdir -p "$(dirname "$2/$rel")" && cp -p "$f" "$2/$rel"
    fi
  done < <(find "$1" -type f)
}

# dep_settings <dep bundle> <its install root> <base|newest>: collect a needed
# bundle's preload, settings and environment for this run.
dep_settings() {
  (
    eval "$(pgext_dzb pgext-bundle "$1/bundle.json" postgres "$2")"
    [ -z "$BUNDLE_PRELOAD" ] || echo "$BUNDLE_PRELOAD" >> "$work/dep-preload-$3"
    [ -z "$BUNDLE_CONF" ] || echo "$BUNDLE_CONF" >> "$work/dep-conf-$3"
    [ -z "$BUNDLE_ENV" ] || echo "$BUNDLE_ENV" >> "$work/dep-env-$3"
  )
}

# verify_in <base|newest>
verify_in() {
  local which="$1" tree pg data sock root conf port v
  tree="$(pgext_pg_tree "$which" "$BUNDLE_PG_MAJOR" "$triple")"
  pg="$work/pg-$which"; data="$work/data-$which"; sock="$work/sock-$which"
  # A throwaway copy: the cached tree is shared and must stay pristine.
  cp -cR "$tree" "$pg" 2>/dev/null || cp -R "$tree" "$pg"
  mkdir -p "$sock"
  conf=""
  if [ "$BUNDLE_PG_MAJOR" -ge 18 ] && [ "${PGEXT_VERIFY_COPY:-0}" != 1 ]; then
    # PG18: the bundle stays in its own folder. An extension_control_path
    # entry names the bundle's share/ — Postgres appends /extension itself
    # (measured on 18.0: an entry ending in share/extension finds nothing) —
    # and a '$libdir/x' module path is then looked up on dynamic_library_path.
    root="$work/ext-$which/$BUNDLE_NAME-$BUNDLE_VERSION"
    mkdir -p "$(dirname "$root")" && cp -R "$bundle" "$root"
    # Each bundle it needs gets a folder of its own too.
    local cpath="$root/share" lpath="$root/lib" d droot
    for d in ${deps[@]+"${deps[@]}"}; do
      droot="$work/ext-$which/$d"
      cp -R "$work/deps/$d" "$droot"
      cpath="$cpath:$droot/share"; lpath="$lpath:$droot/lib"
      dep_settings "$work/deps/$d" "$droot" "$which"
    done
    # Bundles first, then $system / $libdir: the order the module writes
    # (doze-modules postgres preload.go joinPath), so a bundle that ships a
    # name the tree also has is tested the way doze will load it.
    conf="extension_control_path = '$cpath:\$system'
dynamic_library_path = '$lpath:\$libdir'"
    mode="own folder"
  else
    # PG14-17: copy in, never overwriting what the tree ships (a vendored
    # libpq must not replace the tree's newer-minor libpq). Bundles it needs
    # go in first, the way doze installs them.
    root="$pg"
    local d
    for d in ${deps[@]+"${deps[@]}"}; do
      copy_missing "$work/deps/$d/bin" "$pg/bin"
      copy_missing "$work/deps/$d/lib" "$pg/lib"
      copy_missing "$work/deps/$d/share" "$pg/share"
      dep_settings "$work/deps/$d" "$pg" "$which"
    done
    copy_missing "$bundle/bin" "$pg/bin"
    copy_missing "$bundle/lib" "$pg/lib"
    copy_missing "$bundle/share" "$pg/share"
    mode="copied into the tree"
  fi
  # The needed bundles' environment, then this bundle's own.
  [ ! -f "$work/dep-env-$which" ] || . "$work/dep-env-$which"
  eval "$(pgext_dzb pgext-bundle "$bundle/bundle.json" postgres "$root")"
  eval "${BUNDLE_ENV:-:}"
  local preload="$BUNDLE_PRELOAD"
  if [ -s "$work/dep-preload-$which" ]; then
    preload="$(paste -sd, "$work/dep-preload-$which")${preload:+,$preload}"
  fi

  "$pg/bin/initdb" -D "$data" -U postgres --no-sync -E UTF8 --locale=C >/dev/null 2>&1 \
    || pgext_die "initdb ($which) failed"
  port=$(( 20000 + ($$ % 20000) ))
  {
    echo "listen_addresses = ''"
    echo "port = $port"
    echo "unix_socket_directories = '$sock'"
    [ -z "$preload" ] || echo "shared_preload_libraries = '$preload'"
    [ -z "$conf" ] || echo "$conf"
    [ ! -f "$work/dep-conf-$which" ] || cat "$work/dep-conf-$which"
    [ -z "$BUNDLE_CONF" ] || echo "$BUNDLE_CONF"
  } >> "$data/postgresql.conf"
  "$pg/bin/pg_ctl" -D "$data" -l "$work/pg-$which.log" -w start >/dev/null \
    || { cat "$work/pg-$which.log"; pgext_die "postgres $which failed to start with the bundle"; }

  PSQL=("$pg/bin/psql" -h "$sock" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -tAq)
  local r
  for r in $BUNDLE_REQUIRES; do
    "${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS \"$r\" CASCADE" >/dev/null \
      || pgext_die "CREATE EXTENSION $r (required) failed"
  done
  "${PSQL[@]}" -c "CREATE EXTENSION \"$BUNDLE_NAME\" CASCADE" >/dev/null \
    || { tail -20 "$work/pg-$which.log"; pgext_die "CREATE EXTENSION $BUNDLE_NAME failed"; }
  v="$("${PSQL[@]}" -c "SELECT extversion FROM pg_extension WHERE extname = '$BUNDLE_NAME'")"
  local p
  for p in $PROVIDES; do
    "${PSQL[@]}" -c "CREATE EXTENSION \"$p\" CASCADE" >/dev/null \
      || { tail -20 "$work/pg-$which.log"; pgext_die "CREATE EXTENSION $p (provided by $BUNDLE_NAME) failed"; }
    echo "  verify: CREATE EXTENSION $p ok"
  done
  if [ -f "$recipe_dir/smoke.sql" ]; then
    "${PSQL[@]}" -f "$recipe_dir/smoke.sql" >/dev/null \
      || { tail -20 "$work/pg-$which.log"; pgext_die "smoke.sql failed"; }
  fi
  if [ -f "$recipe_dir/smoke.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    PGBIN="$pg/bin" CLIENT_BIN="$root/bin" PGHOST="$sock" PGPORT="$port" PGUSER=postgres PGDATABASE=postgres \
      BUNDLE_ROOT="$bundle" bash -euo pipefail "$recipe_dir/smoke.sh" \
      || pgext_die "smoke.sh failed"
  fi
  # A shipped client program must load from where it lands and report its
  # version. (Scripts are skipped: pg_ivm ships a psql wrapper in bin/.)
  local b
  for b in "$bundle"/bin/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    file -b "$b" | grep -qE 'Mach-O|ELF' || continue
    "$root/bin/$(basename "$b")" --version | grep -q "$BUNDLE_VERSION" \
      || pgext_die "bin/$(basename "$b") does not report $BUNDLE_VERSION"
  done
  "$pg/bin/pg_ctl" -D "$data" stop -m fast >/dev/null
  echo "  verify: ok on $("$pg/bin/postgres" --version | awk '{print $NF}') ($mode; extversion $v)"
}

verify_in base
[ "${PGEXT_VERIFY_BASE_ONLY:-0}" = 1 ] || verify_in newest
echo "  verify: $top ok"
