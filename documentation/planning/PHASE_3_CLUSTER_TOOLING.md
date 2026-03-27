# KubeQuest — Phase 3: Cluster Tooling
> nginx-ingress | Kubernetes Dashboard | kube-prometheus | Loki | Kustomize

---

## Overview

Deploy all cluster management tools using Helm.
All commands in this phase are run **on kube-1** unless stated otherwise.

### What gets deployed and where

| Tool | Namespace | Runs on node |
|------|-----------|--------------|
| nginx-ingress | `ingress-nginx` | `ingress` node (forced via NodeSelector) |
| Kubernetes Dashboard | `kubernetes-dashboard` | any available node |
| Prometheus + Grafana + Alertmanager | `monitoring` | `monitoring` node (forced via NodeSelector) |
| Loki | `monitoring` | `monitoring` node (forced via NodeSelector) |
| Promtail | `monitoring` | **all nodes** (DaemonSet — runs everywhere) |

> You do not SSH into the ingress or monitoring VMs for any of this.
> Kubernetes schedules the pods onto those nodes automatically based on the labels you set in Phase 2.

---

## Prerequisites

- Phase 2 complete — all 4 nodes `Ready` and labeled
- SSH into **kube-1** for everything below

---

## Step 0 — Install Helm

> 🖥️ **Run on: kube-1**

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## Step 1 — Deploy nginx-ingress

> 🖥️ **Run on: kube-1**

nginx-ingress is the entry point for all HTTP/HTTPS traffic into the cluster.
It will be scheduled on the `ingress` node automatically because of `nodeSelector.role=ingress`.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.nodeSelector.role=ingress \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=80 \
  --set controller.service.nodePorts.https=443
```

Wait for it to be ready:

```bash
kubectl get pods -n ingress-nginx -w
# Wait until STATUS = Running, then Ctrl+C
```

Verify it landed on the ingress node:

```bash
kubectl get pods -n ingress-nginx -o wide
# NODE column should show your ingress VM
```

---

## Step 2 — Deploy Kubernetes Dashboard

> 🖥️ **Run on: kube-1**

```bash
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard
helm repo update

helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard \
  --create-namespace
```

Wait for it to be ready:

```bash
kubectl get pods -n kubernetes-dashboard -w
# Wait until STATUS = Running, then Ctrl+C
```

### Create admin user

Create the file `admin-user.yaml`:

```yaml
# admin-user.yaml
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

Apply it:

```bash
kubectl apply -f admin-user.yaml
```

Get your login token (save this for the demo):

```bash
kubectl -n kubernetes-dashboard create token admin-user
```

### Expose Dashboard via Ingress

Create the file `dashboard-ingress.yaml`:

```yaml
# dashboard-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
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

Apply it:

```bash
kubectl apply -f dashboard-ingress.yaml
```

---

## Step 3 — Deploy Prometheus + Grafana + Alertmanager

> 🖥️ **Run on: kube-1**

These will be scheduled on the `monitoring` node automatically.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.nodeSelector.role=monitoring \
  --set grafana.nodeSelector.role=monitoring \
  --set alertmanager.alertmanagerSpec.nodeSelector.role=monitoring \
  --set grafana.adminPassword=admin123
```

This takes 2-3 minutes. Wait for all pods to be ready:

```bash
kubectl get pods -n monitoring -w
# Wait until all show Running, then Ctrl+C
```

### Expose Grafana via Ingress

Create the file `grafana-ingress.yaml`:

```yaml
# grafana-ingress.yaml
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

Apply it:

```bash
kubectl apply -f grafana-ingress.yaml
```

### Expose Prometheus via Ingress

Create the file `prometheus-ingress.yaml`:

```yaml
# prometheus-ingress.yaml
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

Apply it:

```bash
kubectl apply -f prometheus-ingress.yaml
```

---

## Step 4 — Deploy Loki + Promtail

> 🖥️ **Run on: kube-1**

Loki stores logs. Promtail runs on every node and ships logs to Loki.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set loki.nodeSelector.role=monitoring \
  --set promtail.enabled=true \
  --set grafana.enabled=false
```

Verify Promtail is running on every node:

```bash
kubectl get daemonset -n monitoring
# DESIRED should equal your total node count (4)

kubectl get pods -n monitoring -o wide
# You should see one promtail pod per node
```

### Add Loki as a Grafana datasource

Create the file `loki-datasource.yaml`:

```yaml
# loki-datasource.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki:3100
        access: proxy
        isDefault: false
```

Apply it:

```bash
kubectl apply -f loki-datasource.yaml
```

---

## Step 5 — Update Local DNS

> 🖥️ **Run on: your local machine** (not kube-1)

Add these lines to `/etc/hosts` so you can open the tools in your browser.
Use the **public IP of your ingress VM**:

```bash
# macOS / Linux
sudo nano /etc/hosts
```

Add:
```
<INGRESS_IP>  dashboard.kubequest.local
<INGRESS_IP>  grafana.kubequest.local
<INGRESS_IP>  prometheus.kubequest.local
<INGRESS_IP>  app.kubequest.local
```

---

## Step 6 — Verify Everything

> 🖥️ **Run on: kube-1**

```bash
# All pods across all namespaces
kubectl get pods --all-namespaces

# All ingress rules
kubectl get ingress --all-namespaces

# Check namespaces exist
kubectl get namespaces
```

Expected namespaces:
```
NAME                   STATUS
default                Active
ingress-nginx          Active
kubernetes-dashboard   Active
kube-system            Active
monitoring             Active
```

---

## Step 7 — Open in Browser

> 🖥️ **Run on: your local machine**

| URL | Login |
|-----|-------|
| http://grafana.kubequest.local | `admin` / `admin123` |
| http://prometheus.kubequest.local | no login |
| http://dashboard.kubequest.local | paste the token from Step 2 |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod stuck on wrong node | Check node labels: `kubectl get nodes --show-labels` |
| nginx-ingress pod not starting | Check it targets the ingress node: `kubectl get pods -n ingress-nginx -o wide` |
| Grafana not loading in browser | Check ingress: `kubectl get ingress -n monitoring` |
| Promtail not on all nodes | `kubectl get ds -n monitoring` — DESIRED should equal node count |
| Dashboard blank page | Check annotation `backend-protocol: HTTPS` is present |
| Can't reach URLs in browser | Check `/etc/hosts` has the ingress node public IP |

---

## Next Step

**[Phase 4 — Application Helm Chart](./PHASE_4_HELM_CHART.md)**