# KubeQuest — Phase 7: Defense Preparation
> Scripts | Demo flows | Failure endpoints

---

## Overview

Prepare everything needed for a smooth, impressive live demo.
The goal is to never type commands from scratch during the defense — everything runs from scripts.

---

## Scripts Overview

These are the scripts that actually live in `scripts/`:

| Script | Purpose |
|--------|---------|
| `scripts/bootstrap.sh` | Provision a fresh 4-node kubeadm cluster from 4 running AWS VMs — prep, init, Flannel, join, label, kubeconfig |
| `scripts/deploy.sh` | Build the image on kube-1, bump `values-dev.yaml`, push `develop` — ArgoCD (`myapp-dev`) rolls it out. The git push *is* the deploy. |
| `scripts/load-test.sh` | Flood the app (`/cpu`) with requests to trigger HPA auto-scaling |
| `scripts/break-deployment.sh` | Inject a broken image, prove zero downtime, then watch ArgoCD self-heal (automatic rollback) |

> Infra/tooling (nginx-ingress, Dashboard, kube-prometheus, Loki, OPA, Dex) is
> deployed declaratively via Kustomize/Helm + ArgoCD (see PHASE_3 / the
> `infra-gitops/` repo), not a single `deploy-infra.sh`. The `deploy-infra.sh` /
> `deploy-app.sh` blocks further below are kept only as a flat reference of the
> equivalent imperative commands.

---

## scripts/bootstrap.sh  *(real script)*

Provisions a fresh 4-node cluster from your laptop, end to end. It assumes the
4 VMs already exist and are tagged `Name=kube-1|kube-2|ingress|monitoring`
(Amazon Linux 2023), then automates the full Phase 2 runbook:

1. resolves all 4 node IPs from AWS (region `eu-west-3`)
2. preps every node — swap off, kernel modules, sysctl, **containerd via `yum`**,
   k8s repo, `kubelet/kubeadm/kubectl` (`v1.29`)
3. `kubeadm init` on kube-1 (`--pod-network-cidr=10.244.0.0/16`) + Flannel CNI
4. joins kube-2, ingress, monitoring with a freshly generated token
5. removes the control-plane taint, labels `role=ingress` / `role=monitoring`
   (matched by InternalIP, since node names are AWS DNS)
6. copies the kubeconfig here, pointed at kube-1's **public** IP with
   `insecure-skip-tls-verify` (the API cert only covers private IPs)

```bash
./scripts/bootstrap.sh cindy            # fresh cluster
FORCE_RESET=1 ./scripts/bootstrap.sh cindy   # kubeadm reset first, then re-bootstrap
```

> Uses `yum` + `ec2-user`, **not** `apt`/`ubuntu` — Amazon Linux 2023. After it
> finishes, deploy tooling (PHASE_3) and the app (`./scripts/deploy.sh`).
> Worker nodes are reached directly if they have a public IP, else via an SSH
> jump through kube-1.

---

## deploy-infra.sh  *(reference only — real path is Kustomize/Helm + ArgoCD)*

```bash
#!/bin/bash
# deploy-infra.sh — Deploy all cluster tooling
set -e

echo "==> Labeling nodes..."
kubectl label node ingress role=ingress --overwrite
kubectl label node monitoring role=monitoring --overwrite

echo "==> Adding Helm repos..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo add dex https://charts.dexidp.io
helm repo update

echo "==> Deploying nginx-ingress..."
# hostNetwork + DaemonSet so the controller binds node ports 80/443 (see PHASE_3).
# dnsPolicy=ClusterFirstWithHostNet is REQUIRED with hostNetwork — without it the
# pod uses the node's AWS DNS, can't resolve *.svc.cluster.local, and the oauth2-proxy
# auth-url subrequest fails => Grafana/Prometheus/Dashboard return 500.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.nodeSelector.role=ingress \
  --set controller.hostNetwork=true \
  --set controller.hostPort.enabled=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP \
  --set controller.kind=DaemonSet \
  --wait

echo "==> Deploying metrics-server (required by HPA)..."
# Vendored + patched in infra-gitops/base/metrics-server (hostNetwork + insecure-tls
# for this kubeadm/Flannel cluster). Applied early so the HPA has CPU metrics.
kubectl apply -k infra-gitops/base/metrics-server/
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

echo "==> Deploying Kubernetes Dashboard..."
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard --create-namespace \
  --wait

echo "==> Deploying kube-prometheus..."
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.nodeSelector.role=monitoring \
  --set grafana.nodeSelector.role=monitoring \
  --set grafana.adminPassword=admin123 \
  --wait

echo "==> Deploying Loki..."
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --wait

echo "==> Applying Ingress rules..."
kubectl apply -k infra-gitops/overlays/production/

echo "==> Deploying OPA Gatekeeper..."
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --wait

echo "==> Applying OPA policies..."
kubectl apply -f opa/templates/
kubectl apply -f opa/constraints/

echo "✅ All infrastructure components deployed!"
kubectl get pods --all-namespaces
```

---

## deploy-app.sh

```bash
#!/bin/bash
# deploy-app.sh — Deploy the application
set -e

IMAGE_TAG=${1:-"latest"}

echo "==> Creating namespace..."
kubectl create namespace myapp --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating secrets..."
kubectl create secret generic myapp-secret \
  --from-literal=db-password=${DB_PASSWORD:-"defaultpassword"} \
  --from-literal=app-secret=${APP_SECRET:-"defaultsecret"} \
  --namespace myapp \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying application (image tag: $IMAGE_TAG)..."
helm upgrade --install myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=$IMAGE_TAG \
  --set secret.dbPassword=${DB_PASSWORD:-"defaultpassword"} \
  --wait \
  --timeout 5m

echo "==> Verifying rollout..."
kubectl rollout status deployment/myapp -n myapp --timeout=5m

echo "✅ Application deployed successfully!"
kubectl get pods -n myapp
kubectl get ingress -n myapp
```

---

## load-test.sh

```bash
#!/bin/bash
# load-test.sh — Trigger HPA auto-scaling with a load test
set -e

APP_URL=${1:-"http://app.kubequest.local"}
DURATION=${2:-"120"}  # seconds
CONCURRENT=${3:-"50"} # concurrent requests

echo "==> Starting load test against $APP_URL"
echo "==> Duration: ${DURATION}s | Concurrent: $CONCURRENT"
echo ""

# Watch HPA in background
kubectl get hpa -n myapp -w &
HPA_WATCH_PID=$!

# Run load test
if command -v ab &> /dev/null; then
  ab -t $DURATION -c $CONCURRENT "$APP_URL/"
elif command -v hey &> /dev/null; then
  hey -z ${DURATION}s -c $CONCURRENT "$APP_URL/"
else
  echo "Installing hey..."
  go install github.com/rakyll/hey@latest
  hey -z ${DURATION}s -c $CONCURRENT "$APP_URL/"
fi

# Stop HPA watcher
kill $HPA_WATCH_PID 2>/dev/null

echo ""
echo "==> Final HPA state:"
kubectl get hpa -n myapp
echo ""
echo "==> Pod count:"
kubectl get pods -n myapp
```

---

## scripts/break-deployment.sh  *(real script)*

Demonstrates the two safety nets baked into the app deployment, live:

1. **Zero-downtime rolling update** — the Deployment uses `maxUnavailable: 0` +
   a readiness probe, so a broken image never becomes Ready and the old pods
   keep serving. The script proves it with live `curl`s returning `200` *while*
   the new pods sit in `ImagePullBackOff`.
2. **Automatic GitOps rollback** — ArgoCD app `myapp-dev` runs with
   `selfHeal: true`, so drifting the live image away from what git declares makes
   ArgoCD revert it on its own. No human runs the rollback. If self-heal is
   disabled/slow (e.g. the prod app), it falls back to `kubectl rollout undo`.

```bash
./scripts/break-deployment.sh                      # myapp / prod (default, HA)
./scripts/break-deployment.sh myapp-dev myapp-dev  # dev (single pod)
```

Defaults to prod (`myapp`) because it runs 2–6 replicas, so the broken rollout
has live pods to keep serving. Both apps have `selfHeal: true`, so the automatic
rollback works in either namespace.

Flow: record the good image → `kubectl set image` to `…/myapp:broken-<ts>`
(same repo, only the tag is bad → `ImagePullBackOff`) → prove uptime → nudge
ArgoCD (`refresh=hard`) and poll until the live image returns to the git tag →
confirm healthy.

> Assumes `kubectl` already points at the cluster. After a reboot run
> `./scripts/deploy.sh` once first — it refreshes the kube-1 API-server IP.

---

## Failure Endpoints  *(already in the app)*

Both demo endpoints live in the Laravel app at `sample-app/routes/web.php`.
They ship in the image, so just hit them with `curl` (or a browser) during the demo.

### `/cpu` — CPU spike (drives HPA)
Burns CPU for ~5 s per request. Used by `load-test.sh` to push CPU past the HPA
target and trigger scale-up.

```bash
curl http://app-dev.kubequest.local/cpu
```

### `/leak` — memory leak (drives OOMKill)
Allocates memory in real 10 MB chunks and holds it, so the pod's RSS climbs
visibly in Grafana and, past the container memory limit, the pod gets OOMKilled
and auto-restarts. Sets `memory_limit=-1` internally so the *container* limit is
the ceiling, not PHP's.

The app container's memory **limit is `1Gi`** (`charts/myapp/values.yaml`), so
pick `mb` relative to that:

```bash
# Just show the climb in Grafana (stays under the 1Gi limit):
curl "http://app.kubequest.local/leak?mb=256&hold=30"

# Actually trigger the OOMKill + auto-restart (crosses 1Gi):
curl "http://app.kubequest.local/leak?mb=1200&hold=5"

#   ?mb   = total megabytes to allocate (default 256)
#   ?hold = seconds to hold the memory before releasing (default 30)
```

> For the OOM case the pod is killed *during* allocation, so `hold` barely
> matters — keep it small. Watch it with `kubectl -n myapp get pods -w` (the
> `RESTARTS` count ticks up with reason `OOMKilled`). In prod the other
> replicas keep serving while the killed one restarts — zero downtime again.

> These run from the registry image — rebuild + deploy (`./scripts/deploy.sh`)
> after editing the routes for the change to take effect.

---

## Defense Run Order

Follow this exact order during the live demo:

```
1. Run scripts/bootstrap.sh     → fresh 4-node cluster from scratch (kubeadm)
2. Deploy tooling               → Kustomize/Helm + ArgoCD (PHASE_3, infra-gitops)
3. Run scripts/deploy.sh        → app deployed live via GitOps (ArgoCD)
4. Open Grafana                 → show dashboards and metrics
5. Run scripts/load-test.sh     → show HPA scaling up in real time (/cpu)
6. Hit /leak endpoint           → show memory climb + OOMKill/restart in Grafana
7. Run scripts/break-deployment.sh → broken deploy: zero downtime + auto-rollback
8. Show OPA blocking bad pod    → kubectl run with :latest tag
9. Show Dex login               → open protected URL, log in
```

---

## Pre-Defense Checklist

- [ ] All scripts tested at least twice end-to-end
- [ ] `bootstrap.sh` brings up a fresh 4-node cluster (all Ready) in under 10 minutes
- [ ] 4 VMs tagged `kube-1`/`kube-2`/`ingress`/`monitoring` running before the demo
- [ ] All tools accessible via browser (Dashboard, Grafana, Prometheus)
- [ ] HPA scales under load-test.sh (`/cpu`)
- [ ] `/leak` drives RSS up and triggers an OOMKill + restart (visible in Grafana)
- [ ] break-deployment.sh: app stays 200 throughout, then ArgoCD self-heals the image
- [ ] OPA rejects pods without limits and with :latest tags
- [ ] Dex login works on all protected routes
- [ ] `/etc/hosts` file ready on demo machine
- [ ] Grafana dashboards pre-configured and saved
- [ ] Both teammates can run kubectl from their machines

---

## Next Step

Core project is complete. For bonus features proceed to:
**[Phase 8 — Bonuses](./PHASE_8_BONUSES.md)**