SELECT pgmq.create('smoke');
SELECT pgmq.send('smoke', '{"ok": true}');
DO $$ BEGIN
  IF (SELECT count(*) FROM pgmq.read('smoke', 30, 1)) <> 1 THEN
    RAISE EXCEPTION 'pgmq read returned nothing';
  END IF;
END $$;
