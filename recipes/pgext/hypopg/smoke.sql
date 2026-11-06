CREATE TABLE smoke_h (id int, v text);
SELECT * FROM hypopg_create_index('CREATE INDEX ON smoke_h (id)');
DO $$ BEGIN
  IF (SELECT count(*) FROM hypopg_list_indexes) <> 1 THEN
    RAISE EXCEPTION 'hypopg recorded no hypothetical index';
  END IF;
END $$;
