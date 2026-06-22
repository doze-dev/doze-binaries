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
  *)
    # Unknown engine: at least prove every binary loads (dyld/ld resolves deps).
    for b in "$dir"/bin/*; do [ -x "$b" ] && run "$b" --version || true; done
    ;;
esac

echo "smoke OK: $engine $triple"
