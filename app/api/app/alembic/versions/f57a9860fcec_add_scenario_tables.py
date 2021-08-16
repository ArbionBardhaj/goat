"""add_scenario_tables

Revision ID: f57a9860fcec
Revises: 9acb6c82fdb9
Create Date: 2021-08-15 22:20:49.346336

"""
from alembic import op
import sqlalchemy as sa
import geoalchemy2


# revision identifiers, used by Alembic.
revision = 'f57a9860fcec'
down_revision = '9acb6c82fdb9'
branch_labels = None
depends_on = None


def upgrade():
    # ### commands auto generated by Alembic - please adjust! ###
    op.create_table('building_modification',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('building', sa.Integer(), nullable=False),
    sa.Column('building_levels', sa.Integer(), nullable=False),
    sa.Column('building_levels_residential', sa.Integer(), nullable=False),
    sa.Column('gross_floor_area', sa.Integer(), nullable=False),
    sa.Column('population', sa.Integer(), nullable=False),
    sa.Column('origin_id', sa.Integer(), nullable=True),
    sa.Column('scenario_id', sa.Integer(), nullable=False),
    sa.Column('geom', geoalchemy2.types.Geometry(geometry_type='POLYGON', srid=4326, from_text='ST_GeomFromEWKT', name='geometry'), nullable=True),
    sa.ForeignKeyConstraint(['scenario_id'], ['scenario.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_building_modification_id'), 'building_modification', ['id'], unique=False)
    op.create_table('poi_modification',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('name', sa.Text(), nullable=True),
    sa.Column('amenity', sa.Text(), nullable=True),
    sa.Column('opening_hours', sa.Text(), nullable=True),
    sa.Column('wheelchair', sa.Text(), nullable=True),
    sa.Column('origin_id', sa.Integer(), nullable=True),
    sa.Column('scenario_id', sa.Integer(), nullable=False),
    sa.Column('geom', geoalchemy2.types.Geometry(geometry_type='POINT', srid=4326, from_text='ST_GeomFromEWKT', name='geometry'), nullable=True),
    sa.ForeignKeyConstraint(['scenario_id'], ['scenario.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_poi_modification_id'), 'poi_modification', ['id'], unique=False)
    op.create_table('way_modification',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('way_type', sa.Text(), nullable=True),
    sa.Column('surface', sa.Text(), nullable=True),
    sa.Column('wheelchair', sa.Text(), nullable=True),
    sa.Column('lit', sa.Text(), nullable=True),
    sa.Column('street_category', sa.Text(), nullable=True),
    sa.Column('foot', sa.Text(), nullable=True),
    sa.Column('edit_type', sa.Text(), nullable=True),
    sa.Column('bicycle', sa.Text(), nullable=True),
    sa.Column('origin_id', sa.Integer(), nullable=True),
    sa.Column('status', sa.Integer(), nullable=True),
    sa.Column('scenario_id', sa.Integer(), nullable=False),
    sa.Column('geom', geoalchemy2.types.Geometry(geometry_type='POINT', srid=4326, from_text='ST_GeomFromEWKT', name='geometry'), nullable=True),
    sa.ForeignKeyConstraint(['scenario_id'], ['scenario.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_way_modification_id'), 'way_modification', ['id'], unique=False)
    op.drop_index('idx_isochrone_geom', table_name='isochrone')
    op.drop_constraint('scenario_user_id_fkey', 'scenario', type_='foreignkey')
    op.create_foreign_key(None, 'scenario', 'user', ['user_id'], ['id'], ondelete='CASCADE')
    # ### end Alembic commands ###


def downgrade():
    # ### commands auto generated by Alembic - please adjust! ###
    op.drop_constraint(None, 'scenario', type_='foreignkey')
    op.create_foreign_key('scenario_user_id_fkey', 'scenario', 'user', ['user_id'], ['id'])
    op.create_index('idx_isochrone_geom', 'isochrone', ['geom'], unique=False)
    op.drop_index(op.f('ix_way_modification_id'), table_name='way_modification')
    op.drop_table('way_modification')
    op.drop_index(op.f('ix_poi_modification_id'), table_name='poi_modification')
    op.drop_table('poi_modification')
    op.drop_index(op.f('ix_building_modification_id'), table_name='building_modification')
    op.drop_table('building_modification')
    # ### end Alembic commands ###
