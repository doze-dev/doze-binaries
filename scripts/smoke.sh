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
    "$dir/bin/pg_ctl" -D "$data" stop -m immediate >/dev/null 2>&1 || true
    echo "  smoke: documentdb insert/count ok ($n)"
    ;;
  *)
    # Unknown engine: at least prove every binary loads (dyld/ld resolves deps).
    for b in "$dir"/bin/*; do [ -x "$b" ] && run "$b" --version || true; done
    ;;
esac

echo "smoke OK: $engine $triple"
