#!/usr/bin/env bash
# build-template.sh <prefix>
#
# Pre-initialize a PostgreSQL cluster that ALREADY has the DocumentDB extension
# created, and ship it inside the artifact at <prefix>/share/documentdb-template.
#
# First boot is the slow part of DocumentDB on the user's machine: a from-scratch
# initdb plus CREATE EXTENSION documentdb CASCADE (which drags in PostGIS, pg_cron,
# pgvector, RUM, …) costs tens of seconds. Doing it once here, at build time, lets
# doze's `provision` just clone this directory — a local file copy of a second or
# two — so the very first connect comes up quickly. doze rewrites doze.conf and
# pg_hba.conf on boot, so only the cluster catalog (the expensive bit) is reused.
set -euo pipefail

prefix="$1"
tmpl="$prefix/share/documentdb-template"
sock="$(mktemp -d)"
port=54329   # high + unlikely to collide with a Postgres already on the runner

rm -rf "$tmpl"
mkdir -p "$(dirname "$tmpl")"

# A C-locale UTF-8 cluster: the C locale is available on every machine, so the
# shipped cluster starts regardless of which locales the user has installed
# (a locale baked here that's absent there would make Postgres refuse to start).
"$prefix/bin/initdb" -D "$tmpl" -U postgres -A trust --locale=C -E UTF8 --no-sync >/dev/null

# Start with the DocumentDB-required GUCs passed on the command line, so the
# template's postgresql.conf stays pristine (doze regenerates its own doze.conf
# include at boot). listen_addresses=127.0.0.1 matches runtime: the extension and
# pg_cron self-connect over loopback.
"$prefix/bin/pg_ctl" -D "$tmpl" -w -t 120 -l "$tmpl/build-template.log" -o \
  "-k $sock -p $port -c listen_addresses=127.0.0.1 -c shared_preload_libraries=pg_cron,pg_documentdb_core,pg_documentdb -c cron.database_name=postgres" \
  start

# The expensive step — done once, here.
"$prefix/bin/psql" -h "$sock" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -X -q \
  -c "CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;"

"$prefix/bin/pg_ctl" -D "$tmpl" -w -m fast stop

# Drop transient/runtime files. postmaster.pid and postmaster.opts record the
# build-time data + socket paths; leaving them would both be stale at runtime and
# trip smoke.sh's relocation guard (which greps the tarball for build-temp paths).
rm -f "$tmpl/postmaster.pid" "$tmpl/postmaster.opts" "$tmpl/build-template.log"
rm -rf "$tmpl/log" "$tmpl/pg_log"
rmdir "$sock" 2>/dev/null || true

# Sanity: a real cluster carrying the extension.
test -f "$tmpl/PG_VERSION"
"$prefix/bin/postgres" --version >/dev/null
echo "documentdb template built at share/documentdb-template ($(du -sh "$tmpl" | cut -f1))"
