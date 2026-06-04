# KubeQuest — Phase 3: Cluster Tooling
> nginx-ingress | Kubernetes Dashboard | kube-prometheus | Loki | Kustomize

---

## Overview

Deploy all cluster management components via a Kustomize-based GitOps repository.
This repo is your single source of truth for all infrastructure tooling.

> All commands in this phase are run from **kube-1** unless stated otherwise.

---

## ⚠️ Important — AWS Security Group Rules

Do this **before** deploying anything in Phase 3. Without the correct inbound rules you may see:
- 504 Gateway Timeout on Dashboard or Grafana
- `calico-node` pods stuck in `0/1`
- Ingress reachable from the browser but unable to contact backend pods
- Pod-to-pod communication failing across nodes

### Required inbound rules on `kubequest-security-group`

Add these rules in the AWS Console on the Security Group used by all 4 VMs.

| Type | Port | Source | Purpose |
|------|------|--------|---------|
| SSH | 22 | Your IP (or `0.0.0.0/0` for testing) | Connect to VMs |
| HTTP | 80 | `0.0.0.0/0` | Access Dashboard, Grafana, Prometheus |
| HTTPS | 443 | `0.0.0.0/0` | HTTPS services |
| All traffic | All | Same Security Group (`kubequest-security-group`) | Internal cluster communication |

> **Why "All traffic from the same Security Group" is necessary:**
> Your nodes must communicate freely with each other. This is required for Calico networking
> between nodes, ingress reaching pods on another node, and general pod-to-pod communication.
> Without this rule the cluster may look healthy from `kubectl get nodes` but traffic inside
> the cluster will silently break.

### Quick verification after updating the rules

```bash
kubectl get pods -n kube-system -o wide
```

Your Calico pods should show:
```
calico-node-xxxxx   1/1   Running
```

If they are `0/1`, the network is still not healthy — fix the Security Group before continuing.

---

## Repository Structure

```
infra-gitops/
├── base/
│   ├── nginx-ingress/
│   │   └── kustomization.yaml
│   ├── kubernetes-dashboard/
│   │   ├── kustomization.yaml
│   │   ├── admin-user.yaml
│   │   └── ingress.yaml
│   ├── kube-prometheus/
│   │   ├── kustomization.yaml
│   │   ├── grafana-ingress.yaml
│   │   └── prometheus-ingress.yaml
│   └── loki/
│       └── kustomization.yaml
└── overlays/
    └── production/
        └── kustomization.yaml
```

---

## Prerequisites

- Phase 2 complete — cluster running with all nodes Ready
- `kubectl` configured and working
- All 4 VMs joined to the cluster (`kube-1`, `kube-2`, `ingress`, `monitoring`)
- Helm installed on kube-1:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Verify cluster state before starting

```bash
kubectl get nodes
kubectl get nodes --show-labels
kubectl get pods -n kube-system -o wide
```

All nodes should be `Ready`.

---

## Component 1 — nginx-ingress

Deploy on the `ingress` node to handle all external traffic.

> **Why HostNetwork instead of NodePort?**
> Kubernetes restricts NodePort to the range 30000-32767, so you cannot bind directly
> to ports 80/443 with NodePort. `hostNetwork=true` makes the nginx pod bind directly
> to the node's network interface, so it listens natively on ports 80 and 443.

### Label the ingress node

> Do not use `kubectl label node ingress ...` unless your node is literally named `ingress`.
> First find the real Kubernetes node name:

```bash
kubectl get nodes
```

Then label the actual ingress node:

```bash
kubectl label node <INGRESS_NODE_NAME> role=ingress

# Example:
kubectl label node i-00c62469a3d8ca2d4.eu-west-3.compute.internal role=ingress
```

### Add Helm repo

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### Install with HostNetwork + DaemonSet

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.nodeSelector.role=ingress \
  --set controller.hostNetwork=true \
  --set controller.hostPort.enabled=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP \
  --set controller.kind=DaemonSet
```

- `hostNetwork=true` + `hostPort.enabled=true` — binds the pod directly to the node's ports 80 and 443
- `dnsPolicy=ClusterFirstWithHostNet` — **required** with `hostNetwork`. Without it the
  pod falls back to the node's resolver (AWS VPC DNS) and cannot resolve any
  `*.svc.cluster.local`, which breaks the oauth2-proxy `auth-url` subrequest and makes
  Grafana/Prometheus/Dashboard return **500**.
- `kind=DaemonSet` — ensures one pod per matching node
- `service.type=ClusterIP` — external traffic enters via the host network directly, no LoadBalancer needed

### Kustomize manifest

```yaml
# base/nginx-ingress/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
```

> nginx-ingress is deployed via Helm directly. The kustomization.yaml is kept empty
> so the overlay can reference it without error. Helm manages the lifecycle separately.

### Verify

```bash
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx
kubectl get ingressclass
```

Expected: one ingress controller pod running on the ingress node, ports 80/443 reachable on the ingress VM public IP.

Traffic flow:
```
Internet → ingress VM public IP:80/443 → nginx pod (hostNetwork) → ClusterIP services
```

---

## Component 2 — Kubernetes Dashboard

> **Note:** The Helm chart repository for Kubernetes Dashboard is no longer reliably available.
> Install via the official manifest instead — it is simpler and more stable.

### Install via kubectl

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
```

This creates the `kubernetes-dashboard` namespace and all required resources automatically.

### Verify

```bash
kubectl get pods -n kubernetes-dashboard -o wide
kubectl get svc -n kubernetes-dashboard
```

Expected output:
```
dashboard-metrics-scraper-xxx   1/1   Running
kubernetes-dashboard-xxx        1/1   Running
```

### Create admin service account

```yaml
# base/kubernetes-dashboard/admin-user.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
```

```bash
kubectl apply -f base/kubernetes-dashboard/admin-user.yaml

# Get login token — save this for the demo
kubectl -n kubernetes-dashboard create token admin-user
```

### Expose via Ingress

```yaml
# base/kubernetes-dashboard/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: dashboard.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kubernetes-dashboard
                port:
                  number: 443
```

```bash
kubectl apply -f base/kubernetes-dashboard/ingress.yaml
```

### Kustomize manifest

```yaml
# base/kubernetes-dashboard/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - admin-user.yaml
  - ingress.yaml
```

### Verify

```bash
kubectl get ingress -n kubernetes-dashboard
kubectl describe ingress -n kubernetes-dashboard kubernetes-dashboard
```

> If you get a **504 Gateway Timeout**, the most likely cause is broken inter-node communication —
> not the dashboard itself. Check Calico status and the AWS Security Group rules at the top of this doc.

---

## Component 3 — kube-prometheus (Prometheus + Grafana + Alertmanager)

Deploy on the `monitoring` node.

### Label the monitoring node

```bash
# First identify the real node name
kubectl get nodes

# Then label it
kubectl label node <MONITORING_NODE_NAME> role=monitoring

# Example:
kubectl label node i-03fe23d890b52c5e1.eu-west-3.compute.internal role=monitoring
```

### Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.nodeSelector.role=monitoring \
  --set grafana.nodeSelector.role=monitoring \
  --set alertmanager.alertmanagerSpec.nodeSelector.role=monitoring \
  --set grafana.adminPassword=admin123
```

### Expose Grafana via Ingress

```yaml
# base/kube-prometheus/grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
    - host: grafana.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-grafana
                port:
                  number: 80
```

```bash
kubectl apply -f base/kube-prometheus/grafana-ingress.yaml
```

### Expose Prometheus via Ingress

First verify the exact service name:

```bash
kubectl get svc -n monitoring
```

```yaml
# base/kube-prometheus/prometheus-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
    - host: prometheus.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-kube-prome-prometheus
                port:
                  number: 9090
```

```bash
kubectl apply -f base/kube-prometheus/prometheus-ingress.yaml
```

### Kustomize manifest

```yaml
# base/kube-prometheus/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - grafana-ingress.yaml
  - prometheus-ingress.yaml
```

### Verify

```bash
kubectl get pods -n monitoring -o wide
kubectl get ingress -n monitoring
kubectl get svc -n monitoring
```

Access Grafana at `http://grafana.kubequest.local` — login: `admin` / `admin123`

---

## Component 4 — Loki + Promtail

### Install Loki

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set loki.nodeSelector.role=monitoring \
  --set promtail.enabled=true \
  --set grafana.enabled=false
```

> `promtail.enabled=true` deploys Promtail as a DaemonSet automatically on all nodes.

### Add Loki as Grafana datasource

> **⚠️ Do NOT apply a custom grafana-datasource.yaml ConfigMap.**
> `loki-stack` already creates a ConfigMap `loki-loki-stack` with `grafana_datasource: "1"`.
> Adding a second ConfigMap with `isDefault: true` causes Grafana to crash with:
> `datasource.yaml config is invalid. Only one datasource per organization can be marked as default`

Instead, after installing Loki, verify the datasource ConfigMap it created:

```bash
kubectl get configmap -n monitoring -l grafana_datasource=1
# Should show: kube-prometheus-kube-prome-grafana-datasource AND loki-loki-stack
```

Check that `loki-loki-stack` does not have `isDefault: true`:

```bash
kubectl get configmap loki-loki-stack -n monitoring -o yaml | grep isDefault
```

If it does, fix it:

```bash
kubectl edit configmap loki-loki-stack -n monitoring
# Set isDefault: false, then save
```

Then restart Grafana to pick up the datasource:

```bash
kubectl rollout restart deployment/kube-prometheus-grafana -n monitoring
kubectl rollout status deployment/kube-prometheus-grafana -n monitoring
```

### Kustomize manifest

```yaml
# base/loki/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
```

> loki-stack manages its own Grafana datasource ConfigMap. Nothing extra to apply here.

### Verify

```bash
kubectl get pods -n monitoring -o wide
kubectl get daemonset -n monitoring
```

Promtail should appear as a DaemonSet pod on every node.

Once Grafana is running, add Loki manually via the UI if needed:
**Connections → Data Sources → Add → Loki → URL: `http://loki:3100`**

---

## Production Overlay

Wire everything together with a single overlay:

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/nginx-ingress
  - ../../base/kubernetes-dashboard
  - ../../base/kube-prometheus
  - ../../base/loki
```

### Deploy everything at once

```bash
kubectl apply -k overlays/production/
```

---

## Verify All Components

```bash
kubectl get pods --all-namespaces
kubectl get ingress --all-namespaces
kubectl get svc --all-namespaces
```

### Expected namespaces

```
ingress-nginx          — nginx-ingress controller
kubernetes-dashboard   — dashboard
monitoring             — prometheus, grafana, alertmanager, loki, promtail
```

---

## Local DNS (for testing)

Add these entries to your `/etc/hosts` on your **local machine**, pointing to the public IP of the ingress node:

```
<ingress-public-ip>  dashboard.kubequest.local
<ingress-public-ip>  grafana.kubequest.local
<ingress-public-ip>  prometheus.kubequest.local
```

On macOS/Linux:
```bash
sudo nano /etc/hosts
```

Then test connectivity:
```bash
curl http://dashboard.kubequest.local
curl http://grafana.kubequest.local
curl http://prometheus.kubequest.local
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| nginx pod not starting | Check node labels: `kubectl get nodes --show-labels` |
| Port 80/443 not reachable | Check AWS Security Group on ingress VM allows 80 and 443 |
| Dashboard / Grafana returns 504 | Check Calico status and AWS internal cluster traffic rule |
| Calico pods are `0/1` | Add "All traffic" inbound rule from the same Security Group |
| Ingress not routing | Check ingress class: `kubectl get ingressclass` |
| Dashboard login fails | Regenerate token: `kubectl -n kubernetes-dashboard create token admin-user` |
| Grafana not loading | Check logs: `kubectl logs -n monitoring <grafana-pod>` |
| Grafana CrashLoopBackOff — duplicate default datasource | `loki-loki-stack` ConfigMap has `isDefault: true` — edit it to `false` and restart Grafana |
| Promtail not shipping logs | Check DaemonSet: `kubectl get ds -n monitoring` |
| `kubectl apply -k` helm error | nginx-ingress kustomization.yaml must have `resources: []`, not `helmCharts:` |

### Useful debug commands

```bash
kubectl get nodes --show-labels
kubectl get pods -n kube-system -o wide
kubectl get pods -n ingress-nginx -o wide
kubectl get pods -n monitoring -o wide
kubectl get ingress --all-namespaces
kubectl get svc --all-namespaces
```

---

## Next Step

Once all components are running and accessible, proceed to:
**[Phase 4 — Application Helm Chart](./PHASE_4_HELM_CHART.md)**