-- A DiskANN index build and an index-ordered nearest-neighbour query.
CREATE TABLE smoke_items (id int PRIMARY KEY, embedding vector(3));
INSERT INTO smoke_items SELECT i, ARRAY[i, i * 2, i * 3]::real[]::vector FROM generate_series(1, 200) i;
CREATE INDEX smoke_diskann ON smoke_items USING diskann (embedding vector_cosine_ops);
SET enable_seqscan = off;
DO $$ BEGIN
  IF (SELECT count(*) FROM (SELECT id FROM smoke_items ORDER BY embedding <=> '[1,2,3]' LIMIT 5) s) <> 5 THEN
    RAISE EXCEPTION 'vectorscale: the diskann query returned too few rows';
  END IF;
END $$;
