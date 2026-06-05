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
| `scripts/deploy.sh` | Build the image on kube-1, bump `values-dev.yaml`, push `develop` — ArgoCD (`myapp-dev`) rolls it out. The git push *is* the deploy. |
| `scripts/load-test.sh` | Flood the app (`/cpu`) with requests to trigger HPA auto-scaling |
| `scripts/break-deployment.sh` | Inject a broken image, prove zero downtime, then watch ArgoCD self-heal (automatic rollback) |

> Cluster provisioning (kubeadm) and infra/tooling deploy are done out-of-band
> (see PHASE_2 / PHASE_3) — there is no single `bootstrap.sh`/`deploy-infra.sh`
> in the repo. The inline `bootstrap.sh` / `init-control-plane.sh` /
> `deploy-infra.sh` / `deploy-app.sh` blocks below are kept as a reference of the
> end-to-end flow, not as files that exist in `scripts/`.

---

## bootstrap.sh

```bash
#!/bin/bash
# bootstrap.sh — Provision the full cluster from scratch
set -e

echo "==> Provisioning AWS infrastructure with Terraform..."
cd terraform/
terraform init -reconfigure
terraform apply -auto-approve
cd ..

echo "==> Getting node IPs..."
KUBE1_IP=$(terraform -chdir=terraform output -raw kube1_ip)
KUBE2_IP=$(terraform -chdir=terraform output -raw kube2_ip)

echo "==> Waiting for SSH to become available..."
sleep 30

echo "==> Bootstrapping control plane on kube-1..."
ssh -i terraform/keys/kubequest ubuntu@$KUBE1_IP "bash -s" < scripts/init-control-plane.sh

echo "==> Getting join command..."
JOIN_CMD=$(ssh -i terraform/keys/kubequest ubuntu@$KUBE1_IP \
  "kubeadm token create --print-join-command")

echo "==> Joining kube-2 to the cluster..."
ssh -i terraform/keys/kubequest ubuntu@$KUBE2_IP "sudo $JOIN_CMD"

echo "==> Copying kubeconfig..."
scp -i terraform/keys/kubequest ubuntu@$KUBE1_IP:/etc/kubernetes/admin.conf ~/.kube/config
sed -i "s|server: https://.*:6443|server: https://$KUBE1_IP:6443|" ~/.kube/config

echo "==> Verifying cluster..."
kubectl get nodes

echo "✅ Cluster is up and running!"
```

---

## scripts/init-control-plane.sh

```bash
#!/bin/bash
# Runs on kube-1 — installs dependencies and bootstraps the control plane
set -e

# Install dependencies
sudo apt-get update -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates curl containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Disable swap
sudo swapoff -a

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
sudo apt-get install -y -qq kubeadm kubelet kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Initialize cluster
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Set up kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Remove control plane taint (allow scheduling on kube-1)
kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

# Install Flannel CNI
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

---

## deploy-infra.sh

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
1. Bring up cluster + tooling   → kubeadm + Kustomize/Helm (PHASE_2 / PHASE_3)
2. Run scripts/deploy.sh        → app deployed live via GitOps (ArgoCD)
3. Open Grafana                 → show dashboards and metrics
4. Run scripts/load-test.sh     → show HPA scaling up in real time (/cpu)
5. Hit /leak endpoint           → show memory climb + OOMKill/restart in Grafana
6. Run scripts/break-deployment.sh → broken deploy: zero downtime + auto-rollback
7. Show OPA blocking bad pod    → kubectl run with :latest tag
8. Show Dex login               → open protected URL, log in
```

---

## Pre-Defense Checklist

- [ ] All scripts tested at least twice end-to-end
- [ ] Cluster can be reprovisioned in under 10 minutes
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