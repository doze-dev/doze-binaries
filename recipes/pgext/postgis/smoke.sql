-- verify has already created postgis and every name it provides (raster,
-- topology, tiger geocoder, address standardizer + US data). One real call
-- into each part that has C behind it: GEOS, PROJ, GDAL, the topology and
-- address standardizer code, plus MVT (protobuf-c) and GeoJSON (json-c).
DO $$
DECLARE d float8;
BEGIN
  -- PROJ: London -> Paris on the spheroid, ~343.5 km.
  d := ST_Distance('SRID=4326;POINT(-0.1278 51.5074)'::geography, 'SRID=4326;POINT(2.3522 48.8566)'::geography);
  IF d NOT BETWEEN 343000 AND 344500 THEN RAISE EXCEPTION 'postgis: ST_Distance London-Paris = %', d; END IF;
  -- PROJ transform with the shipped proj.db (PROJ_DATA).
  IF abs(ST_X(ST_Transform('SRID=4326;POINT(2.3522 48.8566)'::geometry, 3857)) - 261845.7) > 1 THEN
    RAISE EXCEPTION 'postgis: ST_Transform to 3857 is wrong';
  END IF;
  -- GEOS.
  IF NOT ST_Intersects(ST_Buffer('POINT(0 0)'::geometry, 1), 'POINT(0.5 0.5)'::geometry) THEN
    RAISE EXCEPTION 'postgis: GEOS buffer/intersects';
  END IF;
  -- json-c.
  IF ST_AsText(ST_GeomFromGeoJSON('{"type":"Point","coordinates":[1,2]}')) <> 'POINT(1 2)' THEN
    RAISE EXCEPTION 'postgis: ST_GeomFromGeoJSON';
  END IF;
  -- protobuf-c (MVT).
  IF length((SELECT ST_AsMVT(t) FROM (SELECT ST_AsMVTGeom('POINT(1 1)'::geometry, ST_MakeEnvelope(0, 0, 10, 10)) AS geom) t)) = 0 THEN
    RAISE EXCEPTION 'postgis: ST_AsMVT produced nothing';
  END IF;
  -- address_standardizer (PCRE2) with its US data.
  IF (SELECT house_num FROM standardize_address('us_lex', 'us_gaz', 'us_rules',
        '1 Devonshire Place, Boston, MA 02109')) <> '1' THEN
    RAISE EXCEPTION 'postgis: standardize_address';
  END IF;
END $$;
-- topology: a topology with one edge.
SELECT topology.CreateTopology('smoke_topo', 4326);
SELECT topology.TopoGeo_AddLineString('smoke_topo', 'SRID=4326;LINESTRING(0 0, 1 1)'::geometry);
DO $$ BEGIN
  IF (SELECT count(*) FROM smoke_topo.edge_data) <> 1 THEN RAISE EXCEPTION 'postgis_topology: no edge'; END IF;
END $$;

SET postgis.gdal_enabled_drivers = 'GTiff';
-- postgis_raster (GDAL): a raster made in SQL, read back and written out as
-- a GeoTIFF through a GDAL driver.
DO $$
DECLARE r raster;
BEGIN
  r := ST_AddBand(ST_MakeEmptyRaster(10, 10, 0, 0, 1, -1, 0, 0, 4326), '8BUI'::text, 7, 0);
  IF ST_Value(r, 1, 1) <> 7 THEN RAISE EXCEPTION 'postgis_raster: ST_Value'; END IF;
  IF length(ST_AsGDALRaster(r, 'GTiff')) < 100 THEN RAISE EXCEPTION 'postgis_raster: GTiff via GDAL'; END IF;
  IF (SELECT count(*) FROM ST_GDALDrivers()) = 0 THEN RAISE EXCEPTION 'postgis_raster: no GDAL drivers'; END IF;
END $$;
