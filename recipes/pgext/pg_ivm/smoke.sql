-- An incrementally maintained view must follow an insert into its base table.
CREATE TABLE smoke_base (i int);
SELECT pgivm.create_immv('smoke_immv', 'SELECT i FROM smoke_base');
INSERT INTO smoke_base VALUES (1), (2);
DO $$ BEGIN
  IF (SELECT count(*) FROM smoke_immv) <> 2 THEN
    RAISE EXCEPTION 'pg_ivm view was not maintained';
  END IF;
END $$;
