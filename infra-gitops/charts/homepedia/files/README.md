# Chart-embedded init scripts

The chart loads these into ConfigMaps and mounts them into each database's
`/docker-entrypoint-initdb.d` (they run on **first init only**, i.e. an empty PVC).
They live in the chart (not the app repo) because ArgoCD/Helm can only read files
under the chart path.

| Here | What it is |
|------|------------|
| `postgres-init/01_schema.sql` | **Complete** Postgres schema (generated) — see below |
| `mongo-init/*.js` | Snapshot of the app repo's `apps/CollectData/mongo-init/*.js` |

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
