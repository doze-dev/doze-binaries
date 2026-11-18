-- A cell from a point and back (the h3 core library), then the PostGIS
-- bridge (h3_postgis, created by verify from `provides`) on a geometry.
DO $$ BEGIN
  IF h3_lat_lng_to_cell(POINT(-122.418307270836, 37.7752702151959), 9)::text <> '8928308280fffff' THEN
    RAISE EXCEPTION 'h3: wrong cell for San Francisco at resolution 9: %',
      h3_lat_lng_to_cell(POINT(-122.418307270836, 37.7752702151959), 9);
  END IF;
  IF h3_get_resolution(h3_cell_to_parent('8928308280fffff'::h3index, 5)) <> 5 THEN
    RAISE EXCEPTION 'h3: parent cell has the wrong resolution';
  END IF;
  IF h3_lat_lng_to_cell(ST_SetSRID(ST_MakePoint(-122.418307270836, 37.7752702151959), 4326), 9)::text <> '8928308280fffff' THEN
    RAISE EXCEPTION 'h3_postgis: geometry to cell disagrees with the core';
  END IF;
END $$;
