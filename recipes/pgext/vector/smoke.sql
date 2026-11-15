-- Distance operator plus an HNSW index build: the module's C paths, not just its SQL.
CREATE TABLE smoke_items (id int PRIMARY KEY, embedding vector(3));
INSERT INTO smoke_items VALUES (1, '[1,2,3]'), (2, '[3,2,1]'), (3, '[1,1,1]');
CREATE INDEX ON smoke_items USING hnsw (embedding vector_l2_ops);
SELECT id FROM smoke_items ORDER BY embedding <-> '[1,2,3]' LIMIT 1;
