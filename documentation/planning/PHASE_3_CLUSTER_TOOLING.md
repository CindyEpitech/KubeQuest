# KubeQuest — Phase 3: Cluster Tooling
> nginx-ingress | Kubernetes Dashboard | kube-prometheus | Loki | Kustomize

---

## Overview

Deploy all cluster management components via a Kustomize-based GitOps repository.
This repo is your single source of truth for all infrastructure tooling.

---

## Repository Structure

```
infra-gitops/
├── base/
│   ├── nginx-ingress/
│   │   └── kustomization.yaml
│   ├── kubernetes-dashboard/
│   │   ├── kustomization.yaml
│   │   └── ingress.yaml
│   ├── kube-prometheus/
│   │   └── kustomization.yaml
│   └── loki/
│       ├── kustomization.yaml
│       └── promtail-daemonset.yaml
└── overlays/
    └── production/
        └── kustomization.yaml
```

---

## Prerequisites

- Phase 2 complete — cluster running with both nodes Ready
- `kubectl` configured and working
- Helm installed locally:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Component 1 — nginx-ingress

Deploy on the `ingress` node to handle all external traffic.

### Add Helm repo
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### Create namespace + label the ingress node
```bash
kubectl create namespace ingress-nginx

# Label your ingress node so the controller lands on it
kubectl label node ingress role=ingress
```

### Install with NodeSelector
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.nodeSelector."role"=ingress \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=80 \
  --set controller.service.nodePorts.https=443
```

### Kustomize manifest
```yaml
# base/nginx-ingress/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: ingress-nginx
    repo: https://kubernetes.github.io/ingress-nginx
    version: "4.9.0"
    releaseName: ingress-nginx
    namespace: ingress-nginx
    valuesInline:
      controller:
        nodeSelector:
          role: ingress
        service:
          type: NodePort
```

### Verify
```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

---

## Component 2 — Kubernetes Dashboard

### Install
```bash
kubectl create namespace kubernetes-dashboard

helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard
helm repo update

helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard
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

# Get login token
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

```bash
kubectl apply -f base/kubernetes-dashboard/ingress.yaml
```

---

## Component 3 — kube-prometheus (Prometheus + Grafana + Alertmanager)

Deploy on the `monitoring` node.

### Label the monitoring node
```bash
kubectl label node monitoring role=monitoring
```

### Install kube-prometheus-stack
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

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

### Expose Prometheus via Ingress
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

### Verify
```bash
kubectl get pods -n monitoring
# Access Grafana at http://grafana.kubequest.local (admin / admin123)
```

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
```yaml
# base/loki/grafana-datasource.yaml
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

```bash
kubectl apply -f base/loki/grafana-datasource.yaml
```

### Verify
```bash
kubectl get pods -n monitoring
# Promtail should appear as a DaemonSet pod on every node
kubectl get daemonset -n monitoring
```

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
# All namespaces
kubectl get pods --all-namespaces

# Ingress rules
kubectl get ingress --all-namespaces

# Services
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

Add these entries to your `/etc/hosts` file, pointing to the `ingress` node public IP:

```
<ingress-public-ip>  dashboard.kubequest.local
<ingress-public-ip>  grafana.kubequest.local
<ingress-public-ip>  prometheus.kubequest.local
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pods not scheduling on correct node | Check node labels with `kubectl get nodes --show-labels` |
| Ingress not routing | Check ingress class with `kubectl get ingressclass` |
| Grafana not loading | Check pod logs: `kubectl logs -n monitoring <grafana-pod>` |
| Promtail not shipping logs | Check DaemonSet: `kubectl get ds -n monitoring` |

---

## Next Step

Once all components are running and accessible, proceed to:
**[Phase 4 — Application Helm Chart](./PHASE_4_HELM_CHART.md)**