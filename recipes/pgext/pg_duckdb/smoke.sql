-- DuckDB runs the query (duckdb.query), and DuckDB executes a Postgres table
-- scan when forced on.
DO $$ BEGIN
  IF (SELECT r['s']::bigint FROM duckdb.query('SELECT sum(i) AS s FROM range(1, 101) t(i)') r) <> 5050 THEN
    RAISE EXCEPTION 'pg_duckdb: duckdb.query returned the wrong sum';
  END IF;
END $$;
CREATE TABLE smoke_t (i int);
INSERT INTO smoke_t SELECT generate_series(1, 1000);
SET duckdb.force_execution = true;
DO $$ BEGIN
  IF (SELECT sum(i) FROM smoke_t) <> 500500 THEN
    RAISE EXCEPTION 'pg_duckdb: DuckDB scan of a Postgres table returned the wrong sum';
  END IF;
END $$;
