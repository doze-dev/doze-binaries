-- Dijkstra on a four-node graph: 1->2->4 (cost 2) beats 1->3->4 (cost 5).
CREATE TABLE smoke_edges (id int, source int, target int, cost float8);
INSERT INTO smoke_edges VALUES (1, 1, 2, 1), (2, 2, 4, 1), (3, 1, 3, 1), (4, 3, 4, 4);
DO $$ BEGIN
  IF (SELECT agg_cost FROM pgr_dijkstra('SELECT id, source, target, cost FROM smoke_edges', 1, 4)
      WHERE node = 4) <> 2 THEN
    RAISE EXCEPTION 'pgrouting: wrong shortest path cost';
  END IF;
END $$;
