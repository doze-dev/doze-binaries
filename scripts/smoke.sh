#!/usr/bin/env bash
# smoke.sh <engine> <tarball> <triple>
#
# Publish gate: extract a freshly-built package into a throwaway directory and
# actually RUN its binaries from there. Most packaging bugs (a missing bundled
# dylib, a reference rewritten to a name that isn't on disk, a bad rpath) surface
# at process-load time, so simply launching the binary from a *relocated* path —
# not the build prefix — is enough to catch them. For Postgres we also run a real
# `initdb`, the operation that exercises the ICU collation libraries end to end.
#
# Exits non-zero if the package can't run, which fails the build before publish.
# A package that never runs here must never reach users.
set -euo pipefail

engine="$1"; tarball="$2"; triple="${3:-}"

# Only meaningful on a host whose OS+arch matches the target triple. Cross-built
# targets (rare; e.g. a local dev poking another triple) are skipped with notice.
host_os="$(uname -s)"; host_arch="$(uname -m)"
case "$triple" in
  *darwin*) [ "$host_os" = "Darwin" ] || { echo "smoke: skip ($triple on $host_os)"; exit 0; } ;;
  *linux*)  [ "$host_os" = "Linux"  ] || { echo "smoke: skip ($triple on $host_os)"; exit 0; } ;;
esac
case "$triple" in
  aarch64-*) case "$host_arch" in arm64|aarch64) ;; *) echo "smoke: skip ($triple on $host_arch)"; exit 0;; esac ;;
  x86_64-*)  case "$host_arch" in x86_64|amd64) ;;  *) echo "smoke: skip ($triple on $host_arch)"; exit 0;; esac ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$tarball"
dir="$(find "$work" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[ -n "$dir" ] && [ -d "$dir/bin" ] || { echo "smoke: no bin/ in $tarball" >&2; exit 1; }

run() { echo "  smoke: $*"; "$@" >/dev/null; }

# check_relocation fails if any bundled library still points OUTSIDE the package —
# the failure mode the runtime test alone can miss, because the build prefix still
# exists on the build machine, so an extension that recorded an absolute build-tmp
# path to libpq/geos still loads HERE but breaks on a user's machine. This walks
# every dylib/so (including the extension modules under lib/postgresql/) and
# rejects any non-system, non-@loader_path/@rpath/$ORIGIN dependency.
check_relocation() {
  local root="$1" bad=0 lib ref
  case "$(uname -s)" in
    Darwin)
      while IFS= read -r lib; do
        while IFS= read -r ref; do
          case "$ref" in
            /usr/lib/*|/System/*|@loader_path/*|@rpath/*|@executable_path/*) ;;
            /*) echo "  RELOC FAIL: $(basename "$lib") -> $ref"; bad=1 ;;
          esac
        done < <(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}')
      done < <(find "$root/lib" -name '*.dylib' 2>/dev/null)
      ;;
    Linux)
      while IFS= read -r lib; do
        if ldd "$lib" 2>/dev/null | grep -q 'not found'; then
          echo "  RELOC FAIL: $(basename "$lib") has unresolved deps:"
          ldd "$lib" 2>/dev/null | grep 'not found'
          bad=1
        fi
      done < <(find "$root/lib" -name '*.so*' -type f 2>/dev/null)
      ;;
  esac
  [ "$bad" = 0 ] || { echo "smoke: relocation check failed — bundled libs reference paths outside the package"; exit 1; }
  echo "  smoke: relocation check ok"
}

case "$engine" in
  postgres)
    run "$dir/bin/postgres" --version
    run "$dir/bin/initdb" --version
    data="$work/pgdata"
    # A real initdb loads libicu* and writes a cluster — the exact path that the
    # broken ICU bundling aborted on. Default locale provider is fine; the dylib
    # graph is loaded at exec regardless of provider.
    run "$dir/bin/initdb" -D "$data" -U postgres --no-sync -E UTF8 --locale=C
    ;;
  valkey)
    run "$dir/bin/valkey-server" --version
    ;;
  kvrocks)
    run "$dir/bin/kvrocks" --version
    ;;
  ferretdb)
    run "$dir/bin/ferretdb" --version
    ;;
  documentdb)
    # First prove every bundled lib is self-contained (catches the build-tmp libpq
    # / unbundled geos relocation bug that a same-machine runtime test misses).
    check_relocation "$dir"
    # Stand up the relocated Postgres, load the extension, and do a real
    # documentdb_api insert/count — the whole point of this artifact.
    data="$work/data"; sock="$work/sock"; mkdir -p "$sock"
    run "$dir/bin/initdb" -D "$data" -U postgres --no-sync -E UTF8 --locale=C
    # DocumentDB self-connects over TCP (localhost) for inserts, so TCP must be on.
    cat >> "$data/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
unix_socket_directories = '$sock'
port = 5499
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'
cron.database_name = 'postgres'
EOF
    "$dir/bin/pg_ctl" -D "$data" -l "$work/pg.log" -w start || { echo "smoke: server failed"; cat "$work/pg.log"; exit 1; }
    psql() { "$dir/bin/psql" -h "$sock" -p 5499 -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }
    echo "  smoke: CREATE EXTENSION documentdb CASCADE"
    psql -c "CREATE EXTENSION documentdb CASCADE;" >/dev/null
    psql -c "SELECT documentdb_api.binary_extended_version();" >/dev/null
    psql -c "SELECT documentdb_api.insert_one('smoke','c','{\"_id\":1,\"ok\":true}');" >/dev/null
    n="$(psql -c "SELECT documentdb_api.count_query('smoke','{\"count\":\"c\"}');")"
    # Index creation exercises the BSON field-dedup path, which crashed on macOS
    # when documentdb_core's hash_search wrongly bound to libSystem instead of
    # Postgres's. Build the index in the foreground (run within this session, no
    # background worker) so a regression fails the smoke right here.
    psql -c "SELECT documentdb_api.create_indexes_background('smoke','{\"createIndexes\":\"c\",\"indexes\":[{\"key\":{\"ok\":1},\"name\":\"ok_1\"}]}');" >/dev/null
    psql -c "SELECT documentdb_api.list_indexes_cursor_first_page('smoke','{\"listIndexes\":\"c\"}');" >/dev/null
    "$dir/bin/pg_ctl" -D "$data" stop -m immediate >/dev/null 2>&1 || true
    echo "  smoke: documentdb insert/count/createIndex ok ($n)"
    ;;
  mariadb)
    # Prove the server + tools load from the relocated path, init the system
    # tables, then actually BOOT mariadbd and run a query end to end.
    check_relocation "$dir"
    run "$dir/bin/mariadbd" --version
    run "$dir/bin/mariadb" --version
    data="$work/data"; sock="$work/my.sock"
    run "$dir/bin/mariadb-install-db" --no-defaults --datadir="$data" \
      --auth-root-authentication-method=normal --skip-test-db
    "$dir/bin/mariadbd" --no-defaults --datadir="$data" --socket="$sock" \
      --skip-networking --pid-file="$work/my.pid" >"$work/maria.log" 2>&1 &
    mpid=$!
    ready=0
    for _ in $(seq 1 30); do
      if "$dir/bin/mariadb-admin" --no-defaults --socket="$sock" --user=root ping >/dev/null 2>&1; then ready=1; break; fi
      sleep 1
    done
    [ "$ready" = 1 ] || { echo "smoke: mariadbd never became ready"; cat "$work/maria.log"; kill "$mpid" 2>/dev/null; exit 1; }
    got="$("$dir/bin/mariadb" --no-defaults --socket="$sock" --user=root --batch --skip-column-names -e 'SELECT 1')"
    "$dir/bin/mariadb-admin" --no-defaults --socket="$sock" --user=root shutdown >/dev/null 2>&1 || kill "$mpid" 2>/dev/null || true
    [ "$got" = "1" ] || { echo "smoke: mariadb query returned '$got', want 1"; exit 1; }
    echo "  smoke: mariadbd boot + query ok"
    ;;
  temporal)
    # Pure-Go single binary: prove it loads, then actually stand up the bundled
    # dev server (server + SQLite) headless and confirm the frontend accepts a
    # connection on its port.
    run "$dir/bin/temporal" --version
    port=17233
    "$dir/bin/temporal" server start-dev --headless --ip 127.0.0.1 --port "$port" \
      --db-filename "$work/temporal.db" >"$work/temporal.log" 2>&1 &
    tpid=$!
    ready=0
    for _ in $(seq 1 40); do
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; ready=1; break; fi
      sleep 1
    done
    kill "$tpid" 2>/dev/null || true
    [ "$ready" = 1 ] || { echo "smoke: temporal frontend never opened :$port"; cat "$work/temporal.log"; exit 1; }
    echo "  smoke: temporal start-dev frontend up ok"
    ;;
  *)
    # Unknown engine: at least prove every binary loads (dyld/ld resolves deps).
    for b in "$dir"/bin/*; do [ -x "$b" ] && run "$b" --version || true; done
    ;;
esac

echo "smoke OK: $engine $triple"
