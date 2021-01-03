SELECT * FROM scenarios s 


SELECT * FROM ways_modified wm 

UPDATE ways_modified m
SET edit_type = 'attributes_only'
FROM ways_userinput w
WHERE m.original_id = w.id 
AND ST_EQUALS(ST_ASTEXT(ST_QuantizeCoordinates(m.geom,6)),ST_ASTEXT(ST_QuantizeCoordinates(w.geom,6)))

	
	) u
WHERE u.gid = m.gid;

SELECT ST_QuantizeCoordinates(geom,4)
FROM ways_modified wm 

WITH 

SELECT * FROM ways_modified wm 

DROP TABLE test 

DROP FUNCTION IF EXISTS create_perpendicular_line;
CREATE OR REPLACE FUNCTION create_perpendicular_line(line_geom geometry, point_geom geometry, length_line float)
  RETURNS SETOF geometry AS
$func$

	SELECT ST_SETSRID(
			ST_MAKELINE(
				ST_MAKEPOINT(x2+length_line,y2+(-1/((y2-y1)/(x2-x1)))*length_line), 
				ST_MAKEPOINT(x2-length_line,y2-(-1/((y2-y1)/(x2-x1)))*length_line)
			),4326)
	FROM (
		SELECT ST_X(st_startpoint(line_geom)) x1, ST_Y(st_startpoint(line_geom)) y1, ST_X(point_geom) x2, ST_Y(point_geom) y2 
	) x_y
$func$  LANGUAGE sql IMMUTABLE;


DROP TABLE test; 
CREATE TABLE test AS 
SELECT perpendicular_line(geom, ST_LineInterpolatePoint(geom,0.2),0.0001)
FROM ways_modified wm 



/*TO DO
 1. Remove extend_line and test with snap. 
 2. Better remove close interstion points
 3. Handle Bridges
 4. Properly handle ways with changed attributes
 5. Recompute Slopes + Surface
 */


DROP FUNCTION IF EXISTS network_modification;
CREATE OR REPLACE FUNCTION public.network_modification(scenario_id_input integer)
 RETURNS SETOF integer
 LANGUAGE plpgsql
AS $function$
DECLARE
   i text;
   cnt integer;
   count_bridges integer;
BEGIN
	
	/*Assumption Translation Meters and Degree: 1m = 0.000009 degree */
	DELETE FROM ways_userinput WHERE scenario_id = 3;
	DELETE FROM ways_userinput_vertices_pgr WHERE scenario_id = 3; 
	DROP TABLE IF EXISTS drawn_features, existing_network, intersection_existing_network, drawn_features_union, new_network, delete_extended_part, vertices_to_assign; 
	
	UPDATE ways_modified m
	SET edit_type = 'attributes_only'
	FROM ways_userinput w
	WHERE m.original_id = w.id 
	AND m.scenario_id = 3
	AND ST_EQUALS(ST_ASTEXT(ST_QuantizeCoordinates(m.geom,6)),ST_ASTEXT(ST_QuantizeCoordinates(w.geom,6)));

	UPDATE ways_modified SET status = 1 WHERE scenario_id = 3;
	
	DROP TABLE IF EXISTS modified_attributes_only;
	CREATE TEMP TABLE modified_attributes_only AS 
	SELECT * 
	FROM ways_modified 
	WHERE edit_type = 'attributes_only'
	AND scenario_id = 3;
	CREATE INDEX ON modified_attributes_only USING GIST(geom);

	CREATE TEMP TABLE drawn_features as
	SELECT gid, CASE WHEN way_type = 'bridge' THEN w.geom ELSE el.geom END AS geom, 
	way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id 
	FROM ways_modified w, LATERAL (SELECT extend_line(geom, 0.0000001) geom) AS el
	WHERE scenario_id = 3
	AND (edit_type IS NULL OR edit_type <> 'attributes_only');
	CREATE INDEX ON drawn_features USING GIST(geom);

	/*Intersect drawn ways with existing ways*/
	DROP TABLE IF EXISTS pre_intersection_points;
	CREATE TEMP TABLE pre_intersection_points AS 
	SELECT ST_Intersection(d.geom,w.geom) AS geom
	FROM drawn_features d, ways_userinput w 
	WHERE ST_Intersects(d.geom,w.geom)
	AND w.scenario_id IS NULL
	AND (way_type IS NULL OR way_type = 'road');

	DROP TABLE IF EXISTS intersection_existing_network;
	CREATE TABLE intersection_existing_network AS 
	SELECT 3 AS scenario_id, st_snaptogrid(geom,0.0000001) AS geom
	FROM (
		SELECT DISTINCT (ST_Dumppoints(geom)).geom AS geom
		FROM pre_intersection_points
	) x;
	
	/*Intersects drawn bridges*/
	DROP TABLE IF EXISTS start_end_bridges;
	CREATE TABLE start_end_bridges AS 
	SELECT st_startpoint(geom) AS geom 
	FROM drawn_features
	WHERE way_type = 'bridge'
	UNION 
	SELECT ST_endpoint(geom) 
	FROM drawn_features
	WHERE way_type = 'bridge';
	CREATE INDEX ON start_end_bridges USING GIST(geom);

	INSERT INTO intersection_existing_network
	SELECT 3 AS scenario_id, st_snaptogrid(x.closest_point,0.0000001)
	FROM start_end_bridges s 
	CROSS JOIN LATERAL 
	(
		SELECT ST_CLOSESTPOINT(w.geom,s.geom) AS closest_point,ST_LineLocatePoint(w.geom,s.geom) AS fraction
		FROM ways_userinput w 
		WHERE w.scenario_id IS NULL 
		AND ST_Intersects(St_buffer(s.geom,0.0000001), w.geom)
		ORDER BY ST_CLOSESTPOINT(geom,s.geom) <-> s.geom
	  	LIMIT 1
	) x;

	/*Merge very close intersection points*/
	DROP TABLE IF EXISTS harmonized_intersection_existing_network;
	CREATE TABLE harmonized_intersection_existing_network AS 
	SELECT DISTINCT geom 
	FROM intersection_existing_network;
	DROP TABLE IF EXISTS intersection_existing_network;

	/*Snap new points back to existing network links*/
	CREATE TEMP TABLE intersection_existing_network AS 
	SELECT 3 AS scenario_id, x.closest_point AS geom 
	FROM harmonized_intersection_existing_network s
	CROSS JOIN LATERAL 
	(
		SELECT ST_CLOSESTPOINT(w.geom,s.geom) AS closest_point,ST_LineLocatePoint(w.geom,s.geom) AS fraction
		FROM ways_userinput w 
		WHERE w.scenario_id IS NULL 
		AND ST_Intersects(ST_Buffer(s.geom,0.0000001), w.geom)
		ORDER BY ST_CLOSESTPOINT(geom,s.geom) <-> s.geom
	  	LIMIT 1
	) x;

	ALTER TABLE intersection_existing_network ADD COLUMN gid serial;
	ALTER TABLE intersection_existing_network ADD PRIMARY key(gid);
	CREATE INDEX ON intersection_existing_network USING GIST(geom);

	DROP TABLE IF EXISTS split_drawn_features;
	
	/*Split network with itself*/
	SELECT count(*) 
	INTO cnt
	FROM drawn_features
	WHERE (way_type IS NULL OR way_type <> 'bridge')
	LIMIT 2;
	
	IF cnt <= 1 THEN
	    CREATE TEMP TABLE split_drawn_features as
	    SELECT geom, way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id  
		FROM drawn_features;
	ELSE 
		CREATE TEMP TABLE split_drawn_features as
		SELECT split_by_drawn_lines(gid::integer,geom) AS geom, way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id  
		FROM drawn_features
		WHERE (way_type IS NULL OR way_type <> 'bridge')
		UNION ALL 
		SELECT geom, way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id  
		FROM drawn_features
		WHERE way_type = 'bridge';
	END IF;
	CREATE INDEX ON split_drawn_features USING GIST(geom);

	DROP TABLE IF EXISTS perpendicular_split_lines;
	CREATE TEMP TABLE perpendicular_split_lines AS 
	SELECT p.geom AS geom 
	FROM intersection_existing_network i, split_drawn_features s, LATERAL (SELECT create_perpendicular_line(s.geom, i.geom, 0.0000001) geom) p 
	WHERE ST_Intersects(ST_Buffer(i.geom,0.0000001), s.geom)
	UNION ALL 
	SELECT create_perpendicular_line(x.geom, x.closest_point, 0.0000001) AS geom  
	FROM start_end_bridges s 
	CROSS JOIN LATERAL 
	(
		SELECT ST_CLOSESTPOINT(w.geom,s.geom) AS closest_point, w.geom
		FROM split_drawn_features w
		WHERE ST_Intersects(St_buffer(s.geom,0.0000001), w.geom)
		AND (w.way_type IS NULL OR w.way_type <> 'bridge')
		ORDER BY ST_CLOSESTPOINT(geom,s.geom) <-> s.geom
	  	LIMIT 1
	) x;	

	/*Split new network with existing network*/
	DROP TABLE IF EXISTS new_network;
	CREATE TEMP TABLE new_network AS
	SELECT (dp.geom).geom,	way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id  
	FROM split_drawn_features d, 
	(SELECT ST_UNION(geom) AS geom FROM perpendicular_split_lines) w, 
	LATERAL (SELECT ST_DUMP(ST_CollectionExtract(ST_SPLIT(d.geom,w.geom),2)) AS geom) dp
	WHERE (d.way_type IS NULL OR d.way_type <> 'bridge');
	
	CREATE INDEX ON new_network USING GIST(geom);

	/*Delete extended part*/
	DELETE FROM new_network
	WHERE st_length(geom) < 0.00000011;

	UPDATE new_network d
	SET geom = st_setpoint(d.geom, st_npoints(d.geom)-1, i.geom) 
	FROM intersection_existing_network i 
	WHERE ST_Intersects(ST_Buffer(ST_ENDPOINT(d.geom),0.000001), i.geom);

	UPDATE new_network d
	SET geom = st_setpoint(d.geom, 0, i.geom) 
	FROM intersection_existing_network i 
	WHERE ST_Intersects(ST_Buffer(ST_STARTPOINT(d.geom),0.000001), i.geom);
	
	ALTER TABLE new_network ADD COLUMN gid serial;
	ALTER TABLE new_network ADD COLUMN source integer;
	ALTER TABLE new_network ADD COLUMN target integer;

	/*Inject drawn bridges*/
	INSERT INTO new_network(geom, way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id) 
	SELECT geom, way_type, surface, wheelchair, lit, street_category, foot, bicycle, scenario_id, original_id
	FROM drawn_features 
	WHERE way_type = 'bridge';
	
	--------------------------------EXISTING NETWORK----------------------------------------------------------
	
	/*All the lines FROM the existing network which intersect with the draw network are split*/

	/*Perpendicular lines are generated for each intersection point*/
	DROP TABLE IF EXISTS perpendicular_split_lines;
	CREATE TEMP TABLE perpendicular_split_lines AS 
	SELECT create_perpendicular_line(w.geom, i.geom, 0.0000001) AS geom 
	FROM intersection_existing_network i, ways_userinput w
	WHERE ST_Intersects(ST_Buffer(i.geom,0.0000001), w.geom)
	AND w.scenario_id IS NULL
	AND NOT ST_EQUALS(ST_STARTPOINT(w.geom),i.geom) 
	AND NOT ST_EQUALS(ST_ENDPOINT(w.geom),i.geom);
	
	/*Existing network is split using perpendicular lines*/
	DROP TABLE IF EXISTS existing_network;
	CREATE TEMP TABLE existing_network as 
	SELECT w.id AS original_id, w.class_id, w.surface, w.foot, w.bicycle, (dp.geom).geom, w.source, w.target, w.lit_classified, w.wheelchair_classified, w.impedance_surface
	FROM ways_userinput w, 
	(SELECT ST_UNION(geom) AS geom FROM perpendicular_split_lines) p, 
	LATERAL (SELECT ST_DUMP(ST_CollectionExtract(ST_SPLIT(w.geom,p.geom),2)) AS geom) dp
	WHERE ST_Intersects(w.geom, p.geom)
	AND w.scenario_id IS NULL
	AND w.id NOT IN (SELECT original_id FROM modified_attributes_only);
	
	CREATE INDEX ON existing_network USING GIST(geom);
	
	/*Ways with only changed attributes are split in case they intersect with drawn network*/
	ALTER TABLE new_network ADD COLUMN edit_type TEXT;
	INSERT INTO new_network(original_id, surface, foot, bicycle, geom, lit, wheelchair, edit_type)
	SELECT m.original_id, m.surface, m.foot, m.bicycle, (dp.geom).geom, m.lit, m.wheelchair, 'attributes_only' 
	FROM modified_attributes_only m,
	(SELECT ST_UNION(geom) AS geom FROM perpendicular_split_lines) p, 
	LATERAL (SELECT ST_DUMP(ST_CollectionExtract(ST_SPLIT(m.geom,p.geom),2)) AS geom) dp
	WHERE ST_Intersects(m.geom, p.geom);
	
	/*All ways with only changed attributes that are not touching the drawn network are injected without splitting*/
	INSERT INTO new_network(original_id, surface, foot, bicycle, geom, lit, wheelchair)
	SELECT m.original_id, m.surface, m.foot, m.bicycle, m.geom, m.lit, m.wheelchair, 'attributes_only' 
	FROM modified_attributes_only m
	LEFT JOIN new_network e 
	ON m.original_id = e.original_id  
	WHERE e.original_id IS NULL;

	/*Add vertex_id which is in line with vertices-table*/	
	ALTER TABLE intersection_existing_network ADD COLUMN vertex_id integer;
	UPDATE intersection_existing_network 
	SET vertex_id = (SELECT max(id) FROM ways_userinput_vertices_pgr v) + gid;
	
	/*Set source and target of existing network*/
	UPDATE existing_network set source = x.id 
	FROM (
		SELECT v.id,v.geom 
		FROM ways_userinput_vertices_pgr v, existing_network i
		WHERE v.geom && ST_Buffer(i.geom::geography,0.001)::geometry
		AND v.scenario_id IS NULL
		UNION ALL
		SELECT vertex_id,geom FROM intersection_existing_network
		) x
	WHERE st_startpoint(existing_network.geom) = x.geom;
	
/*
	CREATE TABLE test_to_assign AS 
	SELECT v.id,v.geom 
	FROM ways_userinput_vertices_pgr v, existing_network i
	WHERE v.geom && ST_Buffer(i.geom::geography,0.001)::geometry
	AND v.scenario_id IS NULL
	UNION ALL
	SELECT vertex_id,geom FROM intersection_existing_network
*/

	UPDATE existing_network set target = x.id 
	FROM (
		SELECT v.id,v.geom 
		FROM ways_userinput_vertices_pgr v, existing_network i
		WHERE v.geom && ST_Buffer(i.geom::geography,0.001)::geometry
		AND v.scenario_id IS NULL
		UNION ALL
		SELECT vertex_id,geom FROM intersection_existing_network
	) x
	WHERE st_endpoint(existing_network.geom) = x.geom;
	
	/*Set source and target of new network*/	
	DROP TABLE IF EXISTS start_end_new_network;
	CREATE TEMP TABLE start_end_new_network AS 
	SELECT ST_StartPoint(geom) geom
	FROM new_network
	WHERE (edit_type IS NULL OR edit_type <> 'attributes_only') 
	UNION ALL
	SELECT ST_EndPoint(geom) geom
	FROM new_network
	WHERE (edit_type IS NULL OR edit_type <> 'attributes_only');
	CREATE INDEX ON start_end_new_network USING GIST(geom);

	DROP TABLE IF EXISTS vertices_existing;
	CREATE TEMP TABLE vertices_existing AS 
	SELECT v.id,v.geom 
	FROM ways_userinput_vertices_pgr v, new_network i
	WHERE v.geom && ST_Buffer(i.geom::geography,0.001)::geometry
	AND v.scenario_id IS NULL
	UNION ALL
	SELECT vertex_id,geom FROM intersection_existing_network;
	CREATE INDEX ON vertices_existing USING GIST(geom);	

	DROP TABLE IF EXISTS vertices_to_remove;
	CREATE TEMP TABLE vertices_to_remove AS 
	SELECT s.geom 
	FROM start_end_new_network s, vertices_existing v
	WHERE v.geom && ST_Buffer(s.geom::geography,0.001)::geometry;
	CREATE INDEX ON vertices_to_remove USING GIST(geom);	
	
	DROP TABLE IF EXISTS vertices_to_assign;
	CREATE TEMP TABLE vertices_to_assign AS
	SELECT * FROM vertices_existing 
	UNION ALL 
	SELECT (SELECT max(id) FROM vertices_existing) + row_number() over() as id, s.geom 
	FROM start_end_new_network s 
	LEFT JOIN vertices_to_remove v
	ON s.geom = v.geom 
	WHERE v.geom IS NULL;
	
	CREATE INDEX ON vertices_to_assign USING GIST(geom);

	UPDATE new_network set source = v.id 
	FROM vertices_to_assign v
	WHERE ST_Buffer(ST_StartPoint(new_network.geom)::geography,0.00001)::geometry && v.geom;
	
	UPDATE new_network set target = v.id 
	FROM vertices_to_assign v
	WHERE ST_Buffer(ST_EndPoint(new_network.geom)::geography,0.00001)::geometry && v.geom;
	
	DROP TABLE IF EXISTS network_to_add;
	CREATE TEMP TABLE network_to_add AS 
	SELECT * FROM existing_network  
	UNION ALL 
	SELECT NULL, 100, surface, foot, bicycle, geom, SOURCE, target, lit, wheelchair, NULL 
	FROM new_network;
	
	CREATE INDEX ON network_to_add USING GIST(geom);
	
	---Attach attributes to vertices
	DROP TABLE IF EXISTS vertices_to_add;
	CREATE TEMP TABLE vertices_to_add AS 
	SELECT vv.id, array_remove(array_agg(DISTINCT x.class_id),NULL) class_ids,
	array_remove(array_agg(DISTINCT x.foot),NULL) AS foot,
	array_remove(array_agg(DISTINCT x.bicycle),NULL) bicycle,
	array_remove(array_agg(DISTINCT x.lit_classified),NULL) lit_classified,
	array_remove(array_agg(DISTINCT x.wheelchair_classified),NULL) wheelchair_classified,
	vv.geom
	FROM vertices_to_assign vv
	LEFT JOIN
	(	
		SELECT v.id, w.class_id, w.foot, w.bicycle, w.lit_classified, w.wheelchair_classified 
		FROM vertices_to_assign v, network_to_add w 
		WHERE st_intersects(ST_BUFFER(v.geom,0.00000001),w.geom)
	) x
	ON vv.id = x.id
	GROUP BY vv.id, vv.geom;

	---------------------------------------------------------------------------------------------------------------------
	--INSERT NEW VERTICES AND WAYS INTO THE EXISTING TABLES
	----------------------------------------------------------------------------------------------------------------------
	INSERT INTO ways_userinput_vertices_pgr(id,class_ids, foot, bicycle, lit_classified, wheelchair_classified, geom, scenario_id)
	SELECT va.id::bigint, va.class_ids, va.foot, va.bicycle, va.lit_classified, va.wheelchair_classified, va.geom, 3
	FROM vertices_to_add va
	WHERE va.id >=(SELECT min(vertex_id) from intersection_existing_network); 
	
	INSERT INTO ways_userinput(id,class_id,source,target,foot,bicycle,wheelchair_classified, lit_classified,impedance_surface, geom,scenario_id, original_id) 
	SELECT (SELECT max(id) FROM ways_userinput) + row_number() over(),100,source,target,foot,bicycle,wheelchair_classified, lit_classified,impedance_surface,geom, 3, original_id 
	FROM network_to_add;
	
	UPDATE ways_userinput 
	SET length_m = st_length(geom::geography)
	WHERE length_m IS NULL;

	UPDATE scenarios 
	SET ways_heatmap_computed = FALSE 
	WHERE scenario_id = 3;
		
END
$function$



	SELECT * 
	FROM network_to_add 


	DROP TABLE test_vertices; 
	CREATE TABLE test_vertices AS 
	SELECT * 
	FROM vertices_to_add 

	DROP TABLE test_network; 
	CREATE TABLE test_network AS 
	SELECT * FROM network_to_add
	
	WHERE m.original_id = w.id

	
	SELECT * FROM test_vertices 
	
	INSERT INTO existing_network()
	SELECT * 
	FROM ways_modified 


	DROP TABLE test_intersection; 
	CREATE TABLE test_intersection AS 
	SELECT * FROM intersection_existing_network 
	
	
	SELECT * FROM new_network 
	
	DROP TABLE test_new_network;
	CREATE TABLE test_new_network AS 
	SELECT * FROM new_network;

	CREATE TABLE test_bridges_intersection AS 
	
	DROP TABLE test_existing_network;
	CREATE TABLE test_existing_network AS 
	SELECT * FROM existing_network ;
	SELECT * FROM ways_attributes_only

