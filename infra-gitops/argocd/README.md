# ArgoCD — GitOps for KubeQuest (Phase D.2)

ArgoCD pulls the desired state from this repo and keeps the cluster in sync.
It replaces the `kubectl apply` / `helm upgrade` half of `deploy.sh` with a
pull-based, self-healing loop and a visual UI.

> `deploy.sh` is kept as the fallback/emergency path (and it still does the
> **image build + push + pre-pull**, which ArgoCD does not — see *Caveats*).

## What's here

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Installs ArgoCD (pinned **v2.13.0**) + namespace + ingress, and patches the API server into HTTP/insecure mode |
| `namespace.yaml` | The `argocd` namespace |
| `cmd-params-cm.yaml` | Patch enabling `server.insecure` (TLS terminates at the ingress) |
| `ingress.yaml` | `argocd.kubequest.local` over plain HTTP, consistent with the other services |
| `applications/app-infra.yaml` | Application tracking `infra-gitops/overlays/production` (kustomize) |
| `applications/app-myapp.yaml` | **prod** app: chart on `main` → `myapp` namespace (`values-production.yaml`) |
| `applications/app-myapp-dev.yaml` | **dev** app: chart on `develop` → `myapp-dev` namespace (`values-dev.yaml`) |
| `applications/app-homepedia.yaml` | **prod** app: HomePedia chart on `main` → `homepedia` namespace (`values-production.yaml`) |
| `applications/app-homepedia-dev.yaml` | **dev** app: HomePedia chart on `develop` → `homepedia-dev` namespace (`values-dev.yaml`) |

All `automated.prune=true` + `automated.selfHeal=true`.

## Environments (prod / dev)

The app runs as two ArgoCD Applications, one per branch:

| App | Branch | Namespace | Ingress host | Values |
|-----|--------|-----------|--------------|--------|
| `myapp` (prod) | `main` | `myapp` | `app.kubequest.local` | `values-production.yaml` |
| `myapp-dev` | `develop` | `myapp-dev` | `app-dev.kubequest.local` | `values-dev.yaml` |
| `homepedia` (prod) | `main` | `homepedia` | `homepedia.kubequest.local` | `values-production.yaml` |
| `homepedia-dev` | `develop` | `homepedia-dev` | `homepedia-dev.kubequest.local` | `values-dev.yaml` |

Push to `develop` → dev updates. Merge to `main` → prod updates. Each namespace
gets its **own** standalone MySQL (`mysql.enabled=false`), so the data is
isolated. `infra` stays a single cluster-wide app (not duplicated per env).

### Bootstrapping a fresh app environment

A new namespace has empty secrets and an empty DB, so before/after the app syncs:

```bash
# 1. Pre-create the secrets (ArgoCD does not manage them)
kubectl -n <ns> create secret generic myapp-secret \
  --from-literal=app-key="$APP_KEY"
kubectl -n <ns> create secret generic myapp-db-secret \
  --from-literal=mysql-password="$DB_PASSWORD" \
  --from-literal=mysql-root-password="$DB_ROOT_PASSWORD"

# 2. After the app + MySQL are up, migrate + seed the fresh DB once
#    (run as a one-off Job using the app image — see app-dev bootstrap history,
#     or: php artisan migrate --force --seed)
```

### Bootstrapping HomePedia (`homepedia` / `homepedia-dev`)

HomePedia ships its own in-cluster PostGIS + MongoDB (`postgres.enabled` /
`mongodb.enabled`), so each namespace is isolated. Two prerequisites before the
app can sync healthy:

```bash
# 1. Pre-create the secret (chart uses secret.create=false under GitOps).
#    mongo-uri must embed the same mongo creds + the in-cluster service host.
kubectl -n <ns> create secret generic homepedia-homepedia-secret \
  --from-literal=pg-password="$PG_PASSWORD" \
  --from-literal=mongo-root-password="$MONGO_PASSWORD" \
  --from-literal=mongo-uri="mongodb://homepedia_user:$MONGO_PASSWORD@homepedia-mongodb:27017/?authSource=admin"

# 2. Mirror the stock DB images into the private registry once (the cluster pulls
#    from 10.0.9.227:5000, same as myapp's mysql). Run on kube-1:
#    nerdctl pull postgis/postgis:16-3.4
#    nerdctl tag  postgis/postgis:16-3.4 10.0.9.227:5000/postgis:16-3.4
#    nerdctl push --insecure-registry 10.0.9.227:5000/postgis:16-3.4
#    (repeat for mongo:7.0 -> 10.0.9.227:5000/mongo:7.0)
```

> Postgres/Mongo start **empty** — the init scripts create the schema, but the
> frontend shows real data only once the local ETL/PySpark jobs load it (or a
> dump is restored into the in-cluster DBs).

The frontend image is built by `scripts/deploy-homepedia.sh` from the HomePedia
**app repo** (a different org). kube-1's deploy key only reaches KubeQuest, so the
app repo is cloned over HTTPS with a fine-grained PAT (`Contents: read`). Create
it once on kube-1:

```bash
printf '%s' '<fine-grained-PAT>' > ~/.homepedia_token && chmod 600 ~/.homepedia_token
```

## Install (one-time)

ArgoCD must be installed *before* the Application CRs, so this is two steps.

```bash
# 1. Install ArgoCD itself (CRDs, controllers, ingress, insecure patch)
kubectl apply -k infra-gitops/argocd/

# wait for the server to come up
kubectl -n argocd rollout status deploy/argocd-server

# 2. Register the Applications (now that the Application CRD exists)
kubectl apply -f infra-gitops/argocd/applications/
```

Add `argocd.kubequest.local` to your `/etc/hosts` (same ingress IP as the
other `*.kubequest.local` hosts).

### Log in

```bash
# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# UI:  http://argocd.kubequest.local   (user: admin)
# CLI:
argocd login argocd.kubequest.local --username admin --password <pw> --insecure
```

## Prerequisites / Caveats

These are the things that make GitOps actually work here — read before demoing.

1. **The chart and overlays must exist on `main`.**
   ArgoCD tracks `main`. The Phase A/B/C work currently lives on `develop`,
   so merge `develop → main` (and this branch) before expecting a green sync.

2. **Pre-created secrets** (Application uses `secret.create=false`).
   ArgoCD must not hold plaintext secrets in git, so the myapp chart skips
   rendering them. These Secrets must already exist in the `myapp` namespace:
   - `myapp-secret` → key `app-key` (Laravel `APP_KEY`)
   - `myapp-db-secret` → keys `mysql-password`, `mysql-root-password`

   `deploy.sh` creates these on a normal deploy. To create them standalone:
   ```bash
   kubectl create secret generic myapp-secret -n myapp \
     --from-literal=app-key="$APP_KEY"
   kubectl create secret generic myapp-db-secret -n myapp \
     --from-literal=mysql-password="$DB_PASSWORD" \
     --from-literal=mysql-root-password="$DB_ROOT_PASSWORD"
   ```

3. **ArgoCD does not build images.**
   It only renders + applies manifests. The image must already be in the
   registry (`10.0.9.227:5000/myapp:<tag>`) and pullable by the nodes.
   - Build/push with `deploy.sh` (or CI from Phase D.1).
   - Roll out a new version under GitOps by bumping `image.tag` in
     [`charts/myapp/values-production.yaml`](../charts/myapp/values-production.yaml)
     and pushing to `main`. ArgoCD syncs within ~3 min (or click **Sync**).

4. **Private repo?** If `CindyEpitech/KubeQuest` is private, add repo
   credentials to ArgoCD (`argocd repo add ...` or a `repo-creds` Secret),
   otherwise both Applications report `ComparisonError`.

## Demo flow (pass criterion)

1. Show both Applications **Healthy / Synced** in the UI.
2. Bump `image.tag` in `values-production.yaml`, commit, push to `main`.
3. Watch ArgoCD detect the change and sync the new ReplicaSet within 3 minutes
   — no manual `kubectl`/`helm` command.
