# Chart-embedded init scripts

These files are a **snapshot** copied from the HomePedia app repo
(`EpitechMscProPromo2026/T-DAT-902-NCE_1`):

| Here | Source in the app repo |
|------|------------------------|
| `postgres-init/*.sql` | `apps/CollectData/init-db/*.sql` |
| `mongo-init/*.js` | `apps/CollectData/mongo-init/*.js` |

They live in the chart (not the app repo) because ArgoCD/Helm can only read files
under the chart path. The chart loads them into ConfigMaps and mounts them into
each database's `/docker-entrypoint-initdb.d` (they run on first init only).

> If the init scripts change in the app repo, re-copy them here and bump the
> chart so the in-cluster databases pick up the new schema.
