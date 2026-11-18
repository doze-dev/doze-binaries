-- A graph made and queried in openCypher. age is not preloaded by default
-- (may_preload), so the session loads it, as a user without the preload would.
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
SELECT create_graph('smoke_graph');
SELECT * FROM cypher('smoke_graph', $$
  CREATE (:Person {name: 'ada'})-[:KNOWS]->(:Person {name: 'bob'})
$$) AS (v agtype);
DO $$ BEGIN
  IF (SELECT count(*) FROM cypher('smoke_graph', $c$
        MATCH (:Person {name: 'ada'})-[:KNOWS]->(p:Person {name: 'bob'}) RETURN p.name
      $c$) AS (name agtype)) <> 1 THEN
    RAISE EXCEPTION 'age: the cypher MATCH did not find ada -> bob';
  END IF;
END $$;
