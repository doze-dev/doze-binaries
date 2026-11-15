-- create_parent builds the child partitions; maintenance runs on demand.
CREATE TABLE smoke_events (id bigint, at timestamptz NOT NULL) PARTITION BY RANGE (at);
SELECT create_parent('public.smoke_events', 'at', '1 day');
CALL run_maintenance_proc();
DO $$ BEGIN
  IF (SELECT count(*) FROM pg_inherits WHERE inhparent = 'smoke_events'::regclass) < 2 THEN
    RAISE EXCEPTION 'pg_partman made no partitions';
  END IF;
END $$;
