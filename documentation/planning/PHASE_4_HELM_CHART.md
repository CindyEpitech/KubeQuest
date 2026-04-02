# KubeQuest — Phase 4: Application Helm Chart
> Laravel PHP 8.2 / Apache / Bitnami MySQL 8.0

---

## Overview

The docker-compose app is a **Laravel** application backed by **MySQL 8.0**.
This chart replaces:
- `app` container → Kubernetes Deployment (2 replicas, anti-affinity)
- `db` container → Bitnami MySQL subchart (PVC, existingSecret)
- `traefik` → already covered by nginx-ingress from Phase 3

---

## Chart Structure

```
charts/
└── myapp/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── _helpers.tpl          # Reusable label/name functions
        ├── secret.yaml           # APP_KEY + DB credentials
        ├── configmap.yaml        # Non-sensitive env + MySQL init scripts
        ├── deployment.yaml       # 2 replicas, anti-affinity, initContainer
        ├── service.yaml          # ClusterIP internal load balancer
        ├── ingress.yaml          # Expose via nginx-ingress
        ├── hpa.yaml              # Auto-scaling 2→6 replicas on CPU
        ├── pvc.yaml              # Backup storage volume
        └── cronjob-backup.yaml   # Daily mysqldump, keeps 7 backups
```

---

## Key design decisions

| Topic | Choice | Reason |
|-------|--------|--------|
| Database | Bitnami MySQL (not PostgreSQL) | docker-compose uses MySQL 8.0 |
| DB credentials | `existingSecret: myapp-db-secret` | Bitnami reads `mysql-password` and `mysql-root-password` keys |
| APP_KEY | Secret `myapp-secret` / key `app-key` | Laravel requires this — sensitive |
| initContainer | `busybox` TCP probe on MySQL port | Prevents Laravel crashing before DB is ready |
| Health probe path | `/up` | Laravel 10+ standard health endpoint |
| Replicas | 2 min, 6 max (HPA) | Redundancy + auto-scaling |
| Rolling update | `maxUnavailable: 0` + `minReadySeconds: 10` | Zero-downtime deploys |

---

## Step 1 — Add Bitnami repo & pull dependencies

```bash
# Register the Bitnami Helm repository locally (like apt-add-repository)
helm repo add bitnami https://charts.bitnami.com/bitnami

# Refresh the repo index to get the latest available versions (like apt-get update)
helm repo update

# Read Chart.yaml, download the MySQL subchart from Bitnami,
# and place it in charts/myapp/charts/ so Helm bundles it at deploy time
cd charts/myapp
helm dependency update
```

---

## Step 2 — Build & push image

```bash
# Use the short Git commit hash as the image tag (e.g. a3f9c12)
# Unique per commit, fully traceable — same convention as the CI pipeline
export IMAGE_TAG=$(git rev-parse --short HEAD)

# Build the Docker image from the Dockerfile in the current directory
# and tag it with the full GitLab registry path + commit tag
docker build -t registry.gitlab.com/your-group/myapp:$IMAGE_TAG .

# Push the image to the GitLab registry so the cluster can pull it
docker push registry.gitlab.com/your-group/myapp:$IMAGE_TAG
```

---

## Step 3 — Create namespace & secrets

```bash
# Create an isolated namespace for the app
# All app resources live here, separate from monitoring, ingress-nginx, etc.
kubectl create namespace myapp

# Create the Laravel app Secret
# --from-literal creates a key=value entry directly from the CLI
# Kubernetes stores it base64-encoded internally
kubectl create secret generic myapp-secret \
  --from-literal=app-key="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  -n myapp

# Create the DB credentials Secret
# Key names mysql-password and mysql-root-password are REQUIRED by Bitnami MySQL —
# the subchart looks for exactly these keys when existingSecret is set
kubectl create secret generic myapp-db-secret \
  --from-literal=mysql-password=app_password \
  --from-literal=mysql-root-password=app_root_password \
  -n myapp
```

> Never put real values in `values.yaml`. Always inject at deploy time via `--set` or pre-created Secrets.

---

## Step 4 — Install

```bash
# myapp = release name, prefixes all created resources (e.g. myapp-mysql, myapp-myapp)
# ./charts/myapp = path to the chart
helm install myapp ./charts/myapp \
  \
  # Deploy everything into the myapp namespace
  --namespace myapp \
  \
  # Override values.yaml from the CLI — --set takes priority
  # Tells Helm which image to pull for the app container
  --set image.repository=registry.gitlab.com/your-group/myapp \
  --set image.tag=$IMAGE_TAG \
  \
  # Inject sensitive values at deploy time — these flow into secret.yaml templates
  --set secret.appKey="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  --set secret.dbPassword=app_password \
  --set secret.dbRootPassword=app_root_password \
  \
  # Block until all pods are Ready before returning
  # Without this, the command exits immediately even if pods are still starting
  --wait \
  \
  # If pods are not Ready after 5 minutes, fail the command
  --timeout 5m
```

---

## Step 5 — Verify

```bash
# List all resources in the namespace (pods, deployments, services, replicasets)
kubectl get all -n myapp

# Check Ingress — confirm hostname app.kubequest.local has an IP assigned
kubectl get ingress -n myapp

# Check backup PVC — should be Bound (if Pending, no StorageClass is available)
kubectl get pvc -n myapp

# Check HPA — shows current replica count, CPU metrics, and min/max thresholds
kubectl get hpa -n myapp

# Stream app logs — look for Laravel boot errors (missing APP_KEY, DB unreachable, etc.)
kubectl logs -n myapp deployment/myapp-myapp
```

Add to `/etc/hosts` on your machine:
```
<ingress-public-ip>  app.kubequest.local
```

Then test:
```bash
curl http://app.kubequest.local
```

---

## Upgrade (e.g. new image from CI)

```bash
# helm upgrade updates an existing release
# Helm diffs old and new manifests and only applies what changed
# Changing the image tag triggers a rolling update of the Deployment
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=$NEW_TAG \
  --wait --timeout 5m
```

---

## Lint & dry-run

```bash
# Validate chart syntax and required values — does NOT contact the cluster
helm lint ./charts/myapp

# Render all final YAML manifests and print them — does NOT apply anything
# Useful to debug template rendering issues
helm template myapp ./charts/myapp --debug

# Full simulation: contacts the cluster to validate resources but creates nothing
# Most complete pre-deploy test
helm install myapp ./charts/myapp --dry-run --debug -n myapp
```

---

## Notes on Laravel health endpoint

Laravel 10+ exposes `/up` returning HTTP 200 when healthy (used by readiness + liveness probes).
If your version doesn't have it, add it:

```php
// routes/web.php
Route::get('/up', fn() => response()->json(['status' => 'ok']));
```

Or change the probe path to `/` in `values.yaml`.

---

## Rollback

```bash
# View deployment history
kubectl rollout history deployment/myapp-myapp -n myapp

# Rollback to previous version
kubectl rollout undo deployment/myapp-myapp -n myapp
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod stuck in Init | MySQL not ready — `kubectl logs -n myapp <pod> -c wait-for-mysql` |
| 500 error from Laravel | Missing APP_KEY or DB not migrated — check pod logs |
| HPA not scaling | `kubectl top pods -n myapp` — metrics-server must be running |
| PVC Pending | No default StorageClass — `kubectl get storageclass` |
| DB auth error | Secret keys must be exactly `mysql-password` / `mysql-root-password` |
| Image pull error | Check registry credentials and image path |

---

## Next Step

**[Phase 5 — Application GitOps & CI/CD](./PHASE_5_APP_GITOPS.md)**