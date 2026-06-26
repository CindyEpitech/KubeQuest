# Chart-embedded init scripts

The chart loads these into ConfigMaps and mounts them into each database's
`/docker-entrypoint-initdb.d` (they run on **first init only**, i.e. an empty PVC).
They live in the chart (not the app repo) because ArgoCD/Helm can only read files
under the chart path.

| Here | What it is |
|------|------------|
| `postgres-init/01_schema.sql` | **Complete** base Postgres schema (generated) — see below |
| `postgres-init/02_aggregates.sql` | DVF price aggregate tables — verbatim from app `apps/ProcessDataService/sql/03_create_aggregates.sql` |
| `postgres-init/03_loyers_aggregates.sql` | Loyers (rent) aggregate tables — app `…/04_create_loyers_aggregates.sql` |
| `postgres-init/04_geojson_caches.sql` | Pre-computed GeoJSON cache tables — app `…/05_create_geojson_caches.sql` |
| `mongo-init/*.js` | Snapshot of the app repo's `apps/CollectData/mongo-init/*.js` |

> Init scripts run in filename order: `01` (base schema) → `02`/`03` (aggregates,
> whose FKs reference base tables) → `04` (caches). Validated end-to-end on a fresh
> PostGIS DB with `ON_ERROR_STOP=1`.

## Why `01_schema.sql` is generated, not copied from the app repo

The app repo's `apps/CollectData/init-db/*.sql` is **intentionally minimal** — it
creates base tables, and the ETL then `ALTER TABLE ... ADD COLUMN`s many columns
at runtime (e.g. `indicateurs_communes.nb_arrets` in `load_gtfs.py`,
`zone_sismique` in `load_georisques.py`, POI counts in `load_osm_poi.py`). So the
app repo's init-db never matches the real, post-ETL schema, and a fresh deploy
built from it would be missing columns/indexes (a plain data-only seed then fails).

`01_schema.sql` is therefore a **schema dump of the live DB** (which has the full
post-ETL schema), sanitized to be safe as an init script:

```bash
docker exec homepedia_postgres pg_dump -U homepedia_user -d homepedia \
  --schema-only --no-owner --no-privileges > 01_schema.sql
# then: CREATE SCHEMA topology  ->  CREATE SCHEMA IF NOT EXISTS topology
#       drop the COMMENT ON EXTENSION / COMMENT ON SCHEMA lines
```

> Regenerate + re-sanitize when the app's schema changes (new ETL columns/tables),
> then bump the chart. Validate on a throwaway DB first
> (`createdb t && psql -d t -v ON_ERROR_STOP=1 -f 01_schema.sql`).
>
> **When regenerating, exclude the aggregate/cache tables** so they aren't defined
> twice (they live in `02`–`04`): `pg_dump … --exclude-table='prix*'
> --exclude-table='loyers_*' --exclude-table='geo_cache*'`. `01` = base; `02`–`04`
> = aggregates.

## `02`–`04`: aggregate & GeoJSON-cache tables

These are the analytical tables the frontend's `/api/geo/*` endpoints read
(`prix_moyen_communes`, `prix_moyen_departements`, `loyers_*`, `geo_cache_*`, …).
The app normally builds them in `ProcessDataService` (PySpark); they were absent
from deployed DBs, so the map 500'd with `relation "prix_moyen_communes" does not
exist`. Shipping the DDL here means a **fresh deploy has the tables** (empty) and
the endpoints return 200 instead of 500.

Init only creates them **empty** — populate by running the app's aggregation
pipeline against the target DB. No in-cluster Spark needed (the node is too small);
run it in Docker pointed at a port-forwarded DB:

```bash
docker build -t homepedia_pyspark:latest apps/ProcessDataService     # app repo, once
NS=homepedia                                                          # or homepedia-dev
kubectl -n $NS port-forward svc/homepedia-postgres 5432:5432 &
PGPASS=$(kubectl -n $NS get secret homepedia-homepedia-secret \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
docker run --rm --network host \
  -e POSTGRES_HOST=localhost -e POSTGRES_DB=homepedia \
  -e POSTGRES_USER=homepedia_user -e POSTGRES_PASSWORD="$PGPASS" \
  homepedia_pyspark:latest \
  spark-submit --driver-memory 2g --executor-memory 2g --master 'local[*]' \
    --jars /opt/spark/jars/postgresql-42.7.3.jar /app/scripts/aggregates_pipeline.py
# geojson_pipeline.py additionally fills geo_cache_* (its sentiment step needs Mongo).
# On Docker-Desktop/WSL2 where --network host can't reach the forward, run the
# port-forward inside the container (the public API server is reachable) or use
# host.docker.internal.
```
