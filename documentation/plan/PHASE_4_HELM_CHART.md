# KubeQuest — Phase 4: Application Helm Chart
> Laravel PHP 8.2 / Apache / MySQL 8.0 officiel

---

## Overview

The docker-compose app is a **Laravel** application backed by **MySQL 8.0**.
This chart replaces:
- `app` container → Kubernetes Deployment (2 replicas, anti-affinity)
- `db` container → MySQL officiel (image `mysql:8.0` depuis le registry privé)
- `traefik` → already covered by nginx-ingress from Phase 3

Image registry : **registry:2 running directly on kube-1** (port 5000), built and pushed with nerdctl.
See `REGISTRY.md` for the full registry setup.

---

## Real-world fixes applied

| Problème | Fix |
|----------|-----|
| Bitnami MySQL introuvable sur Docker Hub | Utilisation de l'image officielle `mysql:8.0` + manifest custom (`mysql.yaml`) |
| Bitnami MySQL incompatible avec l'image officielle | Désactivé via `mysql.enabled=false` + `mysql.yaml` custom |
| Pas de StorageClass par défaut | Installation de `local-path-provisioner` (Rancher) |
| DNS cassé dans le cluster | CoreDNS redirigé vers `8.8.8.8` au lieu de `10.0.0.2` (DNS AWS bloqué par Calico) |
| containerd ne résout pas le registry privé | `ctr -n k8s.io images pull --plain-http` sur chaque node pour pre-pull |
| Readiness probe `/up` retourne 404 | Changé en `/` dans `deployment.yaml` |
| Laravel retourne 500 | Migrations non exécutées — lancer `artisan migrate --force` manuellement |
| Service `myapp-mysql` manquant | Créé manuellement via `kubectl apply` |

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
        ├── cronjob-backup.yaml   # Daily mysqldump, keeps 7 backups
        └── mysql.yaml            # MySQL officiel (Deployment + Service + PVC)
```

---

## Prerequisites

### 1. StorageClass (local-path-provisioner)

Sans StorageClass, les PVC restent en `Pending` et MySQL ne démarre pas.

```bash
# Installe local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Vérifie
kubectl get storageclass

# Marque comme défaut
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 2. Fix CoreDNS (DNS cassé avec Calico sur AWS)

Sans ce fix, les pods ne peuvent pas résoudre les noms DNS internes.

```bash
kubectl -n kube-system edit configmap coredns
```

Remplace :
```
forward . /etc/resolv.conf {
```
par :
```
forward . 8.8.8.8 8.8.4.4 {
```

Puis redémarre CoreDNS :
```bash
kubectl rollout restart deployment/coredns -n kube-system
```

### 3. Registry privé sur tous les nodes

Voir `REGISTRY.md`. Sur chaque node, pre-pull les images dans le namespace `k8s.io` :

```bash
sudo ctr -n k8s.io images pull --plain-http 10.0.9.227:5000/myapp:v0.1.0
sudo ctr -n k8s.io images pull --plain-http 10.0.9.227:5000/mysql:8.0
```

---

## Step 1 — Build & push image

See **[REGISTRY.md](./REGISTRY.md)**.

---

## Step 2 — Create namespace

```bash
kubectl create namespace myapp
```

> Les Secrets sont créés automatiquement par Helm via `--set`. Ne pas les créer manuellement avec `kubectl` — sinon Helm refuse de les gérer.

---

## Step 3 — Install

Run from `/home/cindy/projects/KubeQuest/infra-gitops` :

```bash
# Si une release échouée existe déjà
helm uninstall myapp -n myapp
kubectl delete pvc --all -n myapp
kubectl delete svc myapp-mysql -n myapp 2>/dev/null || true

helm install myapp ./charts/myapp \
  --namespace myapp \
  --set image.repository=10.0.9.227:5000/myapp \
  --set image.tag=v0.1.0 \
  --set secret.appKey="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  --set secret.dbPassword=app_password \
  --set secret.dbRootPassword=app_root_password \
  --set mysql.enabled=false
```

> Ne pas utiliser `--wait` lors de la première installation — utilise `kubectl get pods -n myapp` pour suivre manuellement.

### Créer le service MySQL manuellement (si manquant)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: myapp-mysql
  namespace: myapp
spec:
  type: ClusterIP
  ports:
    - port: 3306
      targetPort: 3306
      protocol: TCP
  selector:
    app: mysql
EOF
```

---

## Step 4 — Run migrations

Les migrations Laravel doivent être exécutées une fois après le premier déploiement :

```bash
# Récupère le nom d'un pod app Running
kubectl get pods -n myapp

# Lance les migrations
kubectl exec -n myapp <pod-name> -- php /var/www/html/artisan migrate --force
```

Attendu :
```
Migration table created successfully.
Migrating: 2014_10_12_000000_create_users_table
...
```

---

## Step 5 — Verify

```bash
kubectl get all -n myapp
kubectl get ingress -n myapp
kubectl get pvc -n myapp
```

Ajoute à `/etc/hosts` :
```
<ingress-public-ip>  app.kubequest.local
```

Test :
```bash
curl http://app.kubequest.local
# Attendu : Hello world sample app
```

---

## Upgrade

```bash
# Sur kube-1 — rebuild si code modifié (voir REGISTRY.md)

# Depuis WSL
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=v0.1.1 \
  --set mysql.enabled=false
```

---

## Lint & dry-run

```bash
helm lint ./charts/myapp
helm template myapp ./charts/myapp --debug
helm install myapp ./charts/myapp --dry-run --debug -n myapp
```

---

## Rollback

```bash
kubectl rollout history deployment/myapp-myapp -n myapp
kubectl rollout undo deployment/myapp-myapp -n myapp
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| PVC Pending | StorageClass manquante — installer local-path-provisioner |
| DNS timeout dans les pods | Corriger CoreDNS pour utiliser `8.8.8.8` |
| ImagePullBackOff | Pre-pull avec `ctr -n k8s.io images pull --plain-http` sur le node concerné |
| `cannot re-use a name` | `helm uninstall myapp -n myapp` puis réinstaller |
| `services myapp-mysql already exists` | `kubectl delete svc myapp-mysql -n myapp` |
| Pod stuck Init:0/1 | DNS pas résolu ou service MySQL manquant |
| Pod Running mais 0/1 | Probe échoue — vérifier les logs Apache |
| 500 Laravel | Migrations non exécutées — `artisan migrate --force` |
| Bitnami StatefulSet qui réapparaît | `kubectl delete statefulset myapp-mysql -n myapp` |

---

## Next Step

**[Phase 5 — Application GitOps & CI/CD](./PHASE_5_APP_GITOPS.md)**