from typing import Any

import morecantile
from sqlalchemy.ext.asyncio.session import AsyncSession
from sqlalchemy.sql import text
from fastapi import HTTPException
from src.core.config import settings
from src.schemas.layer import VectorTileFunction, VectorTileTable
from src.db import models 
from src.resources.enums import AllowedVectorTables, SQLReturnTypes

class CRUDLayer:
    # === FETCH TABLES AND FUNCTIONS ===#
    async def table_index(self, db: AsyncSession) -> Any:
        sql = text(
            """
            WITH geo_tables AS (
                SELECT
                    f_table_schema,
                    f_table_name,
                    f_geometry_column,
                    type,
                    srid
                FROM
                    geometry_columns
                WHERE srid <> 0
            ), t AS (
            SELECT
                f_table_schema,
                f_table_name,
                f_geometry_column,
                type,
                srid,
                jsonb_object(
                    array_agg(column_name),
                    array_agg(udt_name)
                ) as coldict,
                (
                    SELECT
                        ARRAY[
                            ST_XMin(extent.geom),
                            ST_YMin(extent.geom),
                            ST_XMax(extent.geom),
                            ST_YMax(extent.geom)
                        ]
                    FROM (
                        SELECT
                            coalesce(
                                ST_Transform(ST_SetSRID(ST_EstimatedExtent(f_table_schema, f_table_name, f_geometry_column), srid), 4326),
                                ST_MakeEnvelope(-180, -90, 180, 90, 4326)
                            ) as geom
                    ) AS extent
                ) AS bounds
            FROM
                information_schema.columns,
                geo_tables
            WHERE
                f_table_schema=table_schema
                AND
                f_table_name=table_name
            GROUP BY
                f_table_schema,
                f_table_name,
                f_geometry_column,
                type,
                srid
            )
            SELECT
                jsonb_agg(
                    jsonb_build_object(
                        'id', concat(f_table_schema, '.', f_table_name),
                        'schema', f_table_schema,
                        'table', f_table_name,
                        'geometry_column', f_geometry_column,
                        'srid', srid,
                        'geometry_type', type,
                        'properties', coldict,
                        'bounds', bounds
                    )
                )
            FROM t
            ;
        """
        )
        result = await db.execute(sql)

        rows = []
        for row in result:
            dict_row = dict(row)
            if dict_row and dict_row["jsonb_agg"]:
                layers = dict_row["jsonb_agg"]
                rows.extend(layers)

        return rows

    # === VECTOR TILE LAYERS ===#
    async def tile_from_table(
        self,
        db: AsyncSession,
        tile: morecantile.Tile,
        tms: morecantile.TileMatrixSet,
        obj_in: VectorTileTable,
        **kwargs: Any,
    ) -> Any:
        """Get Tile Data."""
        bbox = tms.xy_bounds(tile)

        limit = kwargs.get(
            "limit", str(settings.MAX_FEATURES_PER_TILE)
        )  # Number of features to write to a tile.
        columns = kwargs.get(
            "columns"
        )  # Comma-seprated list of properties (column's name) to include in the tile
        resolution = kwargs.get("resolution", str(settings.TILE_RESOLUTION))  # Tile's resolution
        buffer = kwargs.get(
            "buffer", str(settings.TILE_BUFFER)
        )  # Size of extra data to add for a tile.

        limitstr = f"LIMIT {limit}" if int(limit) > -1 else ""
        # create list of columns to return
        geometry_column = obj_in.geometry_column
        cols = obj_in.properties
        if geometry_column in cols:
            del cols[geometry_column]

        if columns is not None:
            include_cols = [c.strip() for c in columns.split(",")]
            for c in cols.copy():
                if c not in include_cols:
                    del cols[c]
        colstring = ", ".join(list(cols))

        segSize = bbox.right - bbox.left
        sql_query = f"""
            WITH
            bounds AS (
                SELECT
                    ST_Segmentize(
                        ST_MakeEnvelope(
                            :xmin,
                            :ymin,
                            :xmax,
                            :ymax,
                            {tms.crs.to_epsg()}
                        ),
                        :seg_size
                    ) AS geom
            ),
            mvtgeom AS (
                SELECT ST_AsMVTGeom(
                    ST_Transform(t.{geometry_column}, {tms.crs.to_epsg()}),
                    bounds.geom,
                    :tile_resolution,
                    :tile_buffer
                ) AS geom, {colstring}
                FROM {obj_in.id} t, bounds
                WHERE ST_Intersects(
                    ST_Transform(t.{geometry_column}, 4326),
                    ST_Transform(bounds.geom, 4326)
                ) {limitstr}
            )
            SELECT ST_AsMVT(mvtgeom.*) FROM mvtgeom
        """
        input_data = {
            "xmin": bbox.left,
            "ymin": bbox.bottom,
            "xmax": bbox.right,
            "ymax": bbox.top,
            "seg_size": segSize,
            "tile_resolution": int(resolution),
            "tile_buffer": int(buffer),
        }
        cursor = await db.execute(sql_query, input_data)
        feature = cursor.first()["st_asmvt"]
        return feature

    async def tile_from_function(
        self,
        db: AsyncSession,
        tile: morecantile.Tile,
        tms: morecantile.TileMatrixSet,
        obj_in: VectorTileFunction,
        **kwargs: Any,
    ) -> Any:
        """Get Tile Data."""
        bbox = tms.xy_bounds(tile)
        async with pool.acquire() as conn:
            transaction = conn.transaction()
            await transaction.start()
            await conn.execute(obj_in.sql)

            function_params = ":xmin, :ymin, :xmax, :ymax, :epsg"
            if kwargs:
                params = ", ".join([f"{k} => {v}" for k, v in kwargs.items()])
                function_params += f", {params}"
            sql_query = text(f"SELECT {obj_in.function_name}({function_params})")
            content = await conn.fetchval_b(
                sql_query,
                xmin=bbox.left,
                ymin=bbox.bottom,
                xmax=bbox.right,
                ymax=bbox.top,
                epsg=tms.crs.to_epsg(),
            )

            await transaction.rollback()

        return content

    async def static_vector_layer(self, db: AsyncSession, current_user: models.User, layer_name: str, return_type: str = 'geojson') -> Any:
        """Get Static Layer Data."""
        
        if layer_name in AllowedVectorTables._member_names_:
            layer_sql = AllowedVectorTables[layer_name].value 
        else:
            raise HTTPException(status_code=400, detail="This layer is not allowed")
        
        if return_type in SQLReturnTypes._member_names_:
            template_sql = SQLReturnTypes[return_type].value
        else:
            raise HTTPException(status_code=400, detail="This return type is not supported")

        sql_query = text(template_sql % 
            f"""
            SELECT * FROM {layer_sql} WHERE study_area_id = :study_area_id
            """
        ) 
        
        result = await db.execute(sql_query, {"study_area_id": current_user.active_study_area_id})
        return result.fetchall()[0][0] 


layer = CRUDLayer()
