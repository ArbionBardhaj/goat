CREATE OR REPLACE FUNCTION basic.create_artificial_edges(sql_network TEXT, point geometry, snap_distance integer, new_node_id integer, line_part1_id integer)
RETURNS TABLE(wid integer, id integer, COST float, reverse_cost float, length_m float, SOURCE integer, target integer, fraction float, geom geometry)
 LANGUAGE plpgsql
AS $function$
DECLARE
	sql_start_vertices TEXT; 
	rec record;
	line_part1 geometry;
	line_part2 geometry;
	length_part1 float;
	length_part2 float;
	line_part2_id integer; 
	buffer geometry; 
	total_length_m float;
BEGIN 
	
	buffer = ST_Buffer(point::geography, snap_distance)::geometry;
  	sql_start_vertices = 'SELECT ST_LineLocatePoint(geom,$2) AS fraction, 
	w.geom AS w_geom, w.SOURCE, w.target, w.COST, w.reverse_cost, $3 AS vid, w.id AS wid
	FROM 
	(
		%1$s	
	) w
	WHERE $1 && geom
	ORDER BY ST_CLOSESTPOINT(geom,$2) <-> $2
  	LIMIT 1;';
  	
  
	EXECUTE format(sql_start_vertices, sql_network) USING buffer, point, new_node_id INTO rec;

 	total_length_m = ST_LENGTH(rec.w_geom::geography);
	line_part1 = ST_LINESUBSTRING(rec.w_geom,0,rec.fraction);
	line_part2 = ST_LINESUBSTRING(rec.w_geom,rec.fraction,1);
	length_part1 = ST_Length(line_part1::geography);
	length_part2 = total_length_m - length_part1;
	line_part2_id = line_part1_id - 1;

  	RETURN query 
	WITH pair_artificial AS (
		SELECT rec.wid, line_part1_id AS id, 
		rec.COST * (length_part1 / total_length_m) AS COST,
		rec.reverse_cost * (length_part1 / total_length_m) AS reverse_cost,
		length_part1 AS length_m, rec.SOURCE, rec.vid AS target, rec.fraction AS fraction, line_part1 AS geom
		UNION ALL
		SELECT rec.wid, line_part2_id AS id,
		rec.COST * (length_part2 / total_length_m) AS COST,
		rec.reverse_cost * (length_part2 / total_length_m) AS reverse_cost,
		length_part2, rec.vid AS SOURCE, rec.target, rec.fraction AS fraction, line_part2 AS geom
	)
	SELECT p.wid, p.id, p.COST, p.reverse_cost, p.length_m, p.SOURCE, p.target, p.fraction, p.geom 
	FROM pair_artificial p
	WHERE p.COST <> 0;
END 
$function$;
/*This function create two artificial edges at starting point 
SELECT * 
FROM basic.create_artificial_edges(
	basic.query_edges_routing(ST_ASTEXT(ST_BUFFER(ST_POINT(11.670883790338209, 48.129792632018706),0.0018)),'default',NULL,1.33,'walking_standard',FALSE),
	ST_SETSRID(ST_POINT(11.670883790338209, 48.129792632018706), 4326), 100, 1, 1
); 
 */