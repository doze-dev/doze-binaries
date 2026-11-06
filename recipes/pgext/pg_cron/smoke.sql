-- Scheduling only works when the preloaded launcher is running in this database.
SELECT cron.schedule('smoke', '* * * * *', 'SELECT 1');
DO $$ BEGIN
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'smoke') <> 1 THEN
    RAISE EXCEPTION 'pg_cron job not recorded';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE backend_type = 'pg_cron launcher') THEN
    RAISE EXCEPTION 'pg_cron launcher is not running (preload?)';
  END IF;
END $$;
