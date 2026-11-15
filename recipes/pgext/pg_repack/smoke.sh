# shellcheck shell=bash

# Run the shipped client against the server: a real online repack.
"$PGBIN/psql" -v ON_ERROR_STOP=1 -qc "CREATE TABLE smoke_r (id int PRIMARY KEY, v text); INSERT INTO smoke_r SELECT g, 'x' FROM generate_series(1, 1000) g; DELETE FROM smoke_r WHERE id % 2 = 0;"
"$CLIENT_BIN/pg_repack" --no-superuser-check -t smoke_r >/dev/null
