# shellcheck shell=bash

# pg_partman's `make install` puts three Python maintenance scripts in bin/
# (dump_partition.py, vacuum_maintenance.py, check_unique_constraint.py). They
# need python3 and psycopg, which doze neither ships nor can assume, so the
# bundle leaves them out; everything they do is also reachable from SQL.
pgext_hook_post_collect() {
  local bundle="$1"
  rm -f "$bundle"/bin/*.py
  [ -n "$(ls -A "$bundle/bin")" ] || touch "$bundle/bin/.keep"
}
