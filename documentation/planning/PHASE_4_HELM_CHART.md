# KubeQuest — Phase 4: Application Helm Chart
> Laravel PHP 8.2 / Apache / Bitnami MySQL 8.0

---

## Overview

The docker-compose app is a **Laravel** application backed by **MySQL 8.0**.
This chart replaces:
- `app` container → Kubernetes Deployment (2 replicas, anti-affinity)
- `db` container → Bitnami MySQL subchart (PVC, existingSecret)
- `traefik` → already covered by nginx-ingress from Phase 3

Image registry : **registry:2 running directly on kube-1** (port 5000), built and pushed with nerdctl.

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
| Registry | registry:2 on kube-1 via nerdctl | Private, no external dependency, accessible via AWS private network |

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

> See **[PHASE_4_REGISTRY.md](./PHASE_4_REGISTRY.md)**.

---

## Step 3 — Create namespace & secrets

Run from your **local machine** (kubectl configured) :

```bash
# Create an isolated namespace for the app
# All app resources live here, separate from monitoring, ingress-nginx, etc.
# Crée un espace isolé dans le cluster uniquement pour ton app. Sans ça, tous tes objets Kubernetes (pods, services, secrets...) iraient dans le namespace `default` mélangés avec le reste. Là tout ce qui concerne l'app vivra dans `myapp`, séparé de `monitoring`, `ingress-nginx`, etc.
kubectl create namespace myapp


# Create the Laravel APP_KEY secret
# --from-literal creates a key=value entry directly from the CLI
# Kubernetes stores it base64-encoded internally
# Crée un objet Kubernetes de type **Secret** nommé `myapp-secret`. Un Secret c'est comme un ConfigMap mais Kubernetes le traite différemment — il ne l'affiche pas en clair dans les logs, et il est encodé en base64 en interne.
# `--from-literal=app-key="..."` crée une entrée dans ce Secret : la clé s'appelle `app-key`, la valeur c'est la Laravel APP_KEY. C'est cette valeur que le template `secret.yaml` du chart va lire et injecter dans le pod comme variable d'environnement `APP_KEY`.
# `-n myapp` : crée ce Secret dans le namespace `myapp`.
kubectl create secret generic myapp-secret \
  --from-literal=app-key="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  -n myapp

# Create the DB credentials secret
# Key names mysql-password and mysql-root-password are REQUIRED by Bitnami MySQL —
# the subchart looks for exactly these keys when existingSecret is set
# Même principe mais avec deux entrées dans le même Secret. Les noms `mysql-password` et `mysql-root-password` ne sont **pas libres** — le chart Bitnami MySQL cherche exactement ces noms de clés quand tu lui indiques `existingSecret: myapp-db-secret` dans `values.yaml`. Si tu les appelles autrement, MySQL ne trouvera pas son mot de passe et ne démarrera pas.
kubectl create secret generic myapp-db-secret \
  --from-literal=mysql-password=app_password \
  --from-literal=mysql-root-password=app_root_password \
  -n myapp
```

> Never put real values in `values.yaml`. Always inject at deploy time via `--set` or pre-created Secrets.

### Pourquoi créer les Secrets avant le `helm install` ?

Parce que le chart référence ces Secrets mais ne les crée pas lui-même depuis des valeurs fixes — il attend qu'ils existent déjà. Si tu fais `helm install` sans avoir créé les Secrets, les pods crashent immédiatement car les variables d'environnement `APP_KEY` et `DB_PASSWORD` sont introuvables.

---

## Step 4 — Install

Run from `/home/cindy/projects/KubeQuest/infra-gitops` :

```bash
# If a previous failed install exists, clean it up first
helm uninstall myapp -n myapp

helm install myapp ./charts/myapp \
  --namespace myapp \
  --set image.repository=10.0.9.227:5000/myapp \
  --set image.tag=v0.1.0 \
  --set secret.appKey="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  --set secret.dbPassword=app_password \
  --set secret.dbRootPassword=app_root_password
```

> Do not use `--wait` during initial setup — if something is wrong it will hang. Check pod status manually with `kubectl get pods -n myapp`. Add `--wait --timeout 5m` only once the chart is confirmed working.

Verify the release is deployed:

```bash
helm list -n myapp
# STATUS should be: deployed
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

Add to `/etc/hosts` on your local machine:
```
<ingress-public-ip>  app.kubequest.local
```

Then test:
```bash
curl http://app.kubequest.local
```

---

## Upgrade (e.g. after a code change)

```bash
# See REGISTRY.md for rebuild + push steps, then:
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=v0.1.1 \
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
| Image pull error | Check containerd config on the node — see `REGISTRY.md` |

---

## Next Step

**[Phase 5 — Application GitOps & CI/CD](./PHASE_5_APP_GITOPS.md)**