# KubeQuest — Phase 4: Application Helm Chart
> Laravel PHP 8.2 / Apache / MySQL 8.0

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
        ├── _helpers.tpl
        ├── secret.yaml          # APP_KEY + DB credentials
        ├── configmap.yaml       # Non-sensitive env + MySQL init scripts
        ├── deployment.yaml      # 2 replicas, anti-affinity, initContainer
        ├── service.yaml
        ├── ingress.yaml
        ├── hpa.yaml
        ├── pvc.yaml             # Backup storage
        └── cronjob-backup.yaml  # Daily mysqldump, keeps 7 backups
```

---

## Key design decisions

| Topic | Choice | Reason |
|-------|--------|--------|
| Database | Bitnami MySQL (not PostgreSQL) | docker-compose uses MySQL 8.0 |
| DB credentials | `existingSecret: myapp-db-secret` | Bitnami reads `mysql-password` and `mysql-root-password` keys |
| APP_KEY | Secret `myapp-secret` / key `app-key` | Laravel requires this — sensitive |
| initContainer | `busybox` TCP probe on MySQL port | Prevents Laravel crashing on startup before DB is ready |
| Health probe path | `/up` | Laravel 10+ standard health endpoint |
| Replicas | 2 min, 6 max (HPA) | Redundancy + auto-scaling |
| Rolling update | `maxUnavailable: 0` + `minReadySeconds: 10` | Zero-downtime deploys |

---

## Step 1 — Add Bitnami repo & pull dependencies

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
cd charts/myapp
helm dependency update
```

---

## Step 2 — Build & push image

```bash
# Tag with commit SHA (matches CI pipeline convention)
export IMAGE_TAG=$(git rev-parse --short HEAD)
docker build -t registry.gitlab.com/your-group/myapp:$IMAGE_TAG .
docker push registry.gitlab.com/your-group/myapp:$IMAGE_TAG
```

---

## Step 3 — Create namespace & secrets

```bash
kubectl create namespace myapp

# App secret (Laravel APP_KEY)
kubectl create secret generic myapp-secret \
  --from-literal=app-key="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  -n myapp

# DB credentials (consumed by Bitnami MySQL via existingSecret)
kubectl create secret generic myapp-db-secret \
  --from-literal=mysql-password=app_password \
  --from-literal=mysql-root-password=app_root_password \
  -n myapp
```

> Never put real values in `values.yaml`. Always inject via `--set` or pre-created Secrets.

---

## Step 4 — Install

```bash
helm install myapp ./charts/myapp \
  --namespace myapp \
  --set image.repository=registry.gitlab.com/your-group/myapp \
  --set image.tag=$IMAGE_TAG \
  --set secret.appKey="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  --set secret.dbPassword=app_password \
  --set secret.dbRootPassword=app_root_password \
  --wait --timeout 5m
```

---

## Step 5 — Verify

```bash
kubectl get all -n myapp
kubectl get ingress -n myapp
kubectl get pvc -n myapp
kubectl get hpa -n myapp

# Logs
kubectl logs -n myapp deployment/myapp-myapp

# Test via ingress (add to /etc/hosts first)
# <ingress-ip>  app.kubequest.local
curl http://app.kubequest.local
```

---

## Upgrade (e.g. new image tag from CI)

```bash
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=$NEW_TAG \
  --wait --timeout 5m
```

---

## Lint & dry-run

```bash
helm lint ./charts/myapp
helm template myapp ./charts/myapp --debug
helm install myapp ./charts/myapp --dry-run --debug -n myapp
```

---

## /etc/hosts entry

```
<ingress-public-ip>  app.kubequest.local
```

---

## Notes on Laravel health endpoint

Laravel 10+ exposes `/up` returning HTTP 200 when the app is healthy.
If your version doesn't have it, either add it manually:

```php
// routes/web.php
Route::get('/up', fn() => response()->json(['status' => 'ok']));
```

or change the probe path to `/` in `values.yaml`.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod stuck in Init | MySQL not ready yet — check `kubectl logs -n myapp <pod> -c wait-for-mysql` |
| 500 error from Laravel | Missing APP_KEY or DB not migrated — check pod logs |
| HPA not scaling | Ensure metrics-server is running: `kubectl top pods -n myapp` |
| PVC Pending | No default StorageClass — check `kubectl get storageclass` |
| DB password wrong | Secret keys must be `mysql-password` / `mysql-root-password` exactly |

---

## Next Step

**[Phase 5 — Application GitOps & CI/CD](./PHASE_5_APP_GITOPS.md)**