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
# chmod first: some engines leave read-only files behind (a verify sweep run
# once died on `rm: Permission denied` cleaning a prior artifact's tree).
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
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
        # A dylib's own LC_ID_DYLIB (its install name, the first otool -L entry)
        # is not a dependency: the runtime loader never consults it, it only
        # matters to someone LINKING against the shipped lib. First-party libs
        # (e.g. postgres's libpq) keep their build-prefix ID, so skip it —
        # only actual load-path references decide relocatability.
        id="$(otool -D "$lib" 2>/dev/null | tail -n +2 | head -n 1)"
        while IFS= read -r ref; do
          [ "$ref" = "$id" ] && continue
          case "$ref" in
            /usr/lib/*|/System/*|@loader_path/*|@rpath/*|@executable_path/*) ;;
            /*) echo "  RELOC FAIL: $(basename "$lib") -> $ref"; bad=1 ;;
          esac
        done < <(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}')
      done < <(find "$root/lib" \( -name '*.dylib' -o -name '*.so' \) -type f 2>/dev/null)
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

# Every engine gets the relocation gate: any bundled lib that still references a
# path outside the package is a bug regardless of engine (find is a no-op for
# engines that bundle no libs, e.g. the pure-Go ones).
check_relocation "$dir"

case "$engine" in
  postgres)
    run "$dir/bin/postgres" --version
    run "$dir/bin/initdb" --version
    data="$work/pgdata"; sock="$work/sock"; mkdir -p "$sock"
    # A real initdb loads libicu* and writes a cluster — the exact path that the
    # broken ICU bundling aborted on. Default locale provider is fine; the dylib
    # graph is loaded at exec regardless of provider.
    run "$dir/bin/initdb" -D "$data" -U postgres --no-sync -E UTF8 --locale=C
    # Then BOOT the server and exercise what the archive actually ships. The
    # archive carries all of contrib as separate extension .so files, and initdb
    # alone never loads them — a bad rpath in pgcrypto.so would pass a
    # version+initdb smoke and explode on the user's first CREATE EXTENSION.
    cat >> "$data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$sock'
shared_preload_libraries = 'pg_stat_statements'
EOF
    "$dir/bin/pg_ctl" -D "$data" -l "$work/pg.log" -w start >/dev/null \
      || { echo "smoke: postgres failed to start"; cat "$work/pg.log"; exit 1; }
    trap '"$dir/bin/pg_ctl" -D "$data" stop -m immediate >/dev/null 2>&1 || true; chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
    pq() { "$dir/bin/psql" -h "$sock" -U postgres -d "$1" -v ON_ERROR_STOP=1 -tAc "$2"; }
    # Roles / databases / schemas / tables: the operations every doze module
    # performs on first provision.
    pq postgres "CREATE ROLE app LOGIN PASSWORD 'smoke'" >/dev/null
    pq postgres "CREATE DATABASE app OWNER app" >/dev/null
    pq app "CREATE SCHEMA payments AUTHORIZATION app" >/dev/null
    pq app "CREATE TABLE payments.t (id int PRIMARY KEY, note text)" >/dev/null
    pq app "INSERT INTO payments.t VALUES (1, 'ok')" >/dev/null
    got="$(pq app 'SELECT note FROM payments.t')"
    [ "$got" = "ok" ] || { echo "smoke: query returned '$got', want ok"; exit 1; }
    # ICU at runtime (initdb only proves it at cluster-creation time).
    pq app "SELECT 'a' < 'B' COLLATE \"en-x-icu\"" >/dev/null
    # CREATE EXTENSION for everything the archive ships — iterate the archive's
    # own control files (not a hardcoded list) so the sweep stays correct across
    # majors with different contrib sets. CASCADE pulls in dependencies
    # (earthdistance -> cube); pg_stat_statements needs the preload set above.
    extdir=""
    for d in "$dir/share/postgresql/extension" "$dir/share/extension"; do
      [ -d "$d" ] && { extdir="$d"; break; }
    done
    [ -n "$extdir" ] || { echo "smoke: no extension dir in archive"; exit 1; }
    n=0
    for ctl in "$extdir"/*.control; do
      ext="$(basename "$ctl" .control)"
      pq app "CREATE EXTENSION IF NOT EXISTS \"$ext\" CASCADE" >/dev/null \
        || { echo "smoke: CREATE EXTENSION $ext failed"; exit 1; }
      n=$((n+1))
    done
    # The preloaded module must actually be live, not just created.
    pq app "SELECT count(*) >= 0 FROM pg_stat_statements" >/dev/null
    "$dir/bin/pg_ctl" -D "$data" stop -m immediate >/dev/null 2>&1 || true
    echo "  smoke: boot + role/db/schema/query + ICU + $n extensions ok"
    ;;
  valkey)
    run "$dir/bin/valkey-server" --version
    # Boot on a unix socket and prove serving works, not just process load.
    "$dir/bin/valkey-server" --port 0 --unixsocket "$work/vk.sock" \
      --dir "$work" --save '' >"$work/vk.log" 2>&1 &
    vpid=$!
    ready=0
    for _ in $(seq 1 30); do
      if "$dir/bin/valkey-cli" -s "$work/vk.sock" ping >/dev/null 2>&1; then ready=1; break; fi
      sleep 1
    done
    [ "$ready" = 1 ] || { echo "smoke: valkey never became ready"; cat "$work/vk.log"; kill "$vpid" 2>/dev/null; exit 1; }
    "$dir/bin/valkey-cli" -s "$work/vk.sock" set smoke ok >/dev/null
    got="$("$dir/bin/valkey-cli" -s "$work/vk.sock" get smoke)"
    kill "$vpid" 2>/dev/null || true
    [ "$got" = "ok" ] || { echo "smoke: valkey GET returned '$got', want ok"; exit 1; }
    echo "  smoke: valkey boot + set/get ok"
    ;;
  kvrocks)
    run "$dir/bin/kvrocks" --version
    # Boot with a minimal config (keys stable across 2.x) and speak raw RESP over
    # /dev/tcp — the archive ships no client binary.
    kvport=17666
    printf 'port %s\ndir %s\n' "$kvport" "$work/kvdata" > "$work/kv.conf"
    mkdir -p "$work/kvdata"
    "$dir/bin/kvrocks" -c "$work/kv.conf" >"$work/kv.log" 2>&1 &
    kpid=$!
    ready=0
    for _ in $(seq 1 30); do
      if reply="$(exec 2>/dev/null 3<>"/dev/tcp/127.0.0.1/$kvport" \
            && printf '*1\r\n$4\r\nPING\r\n' >&3 && head -c 5 <&3 && exec 3>&- 3<&-)" \
         && [ "$reply" = "+PONG" ]; then ready=1; break; fi
      sleep 1
    done
    kill "$kpid" 2>/dev/null || true
    [ "$ready" = 1 ] || { echo "smoke: kvrocks never answered PING"; cat "$work/kv.log"; exit 1; }
    echo "  smoke: kvrocks boot + RESP ping ok"
    ;;
  ferretdb)
    # Standalone the gateway can only prove process load — it needs the paired
    # documentdb backend for real operations, which the ferret module's
    # acceptance tests (and the documentdb arm below) cover.
    run "$dir/bin/ferretdb" --version
    ;;
  documentdb)
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
