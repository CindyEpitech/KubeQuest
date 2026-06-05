# KubeQuest — Phase 8: Bonuses
> ArgoCD | cert-manager | Zero-downtime | Private registry | Network policies

---

## Overview

Bonus features to maximize the demo impact and score.
Tackle these in priority order after the core phases are complete and tested.

> The sections below are the original planning notes (generic examples — Postgres,
> ECR, Let's Encrypt). For **what was actually implemented and how to demo it**,
> see the runbook immediately below; it is the source of truth.

---

## Demonstrating the bonuses (defense runbook)

What's implemented, and the exact way to show each on the live cluster. Two
narrated, `[Enter]`-paced scripts do most of it:

```bash
./scripts/demo-bonuses.sh      # ArgoCD, registry, lightweight image, TLS, NetPol, RBAC
./scripts/demo-rollback.sh     # zero-downtime + automatic rollback
```

> Prep: cert-manager is installed via **helm, not GitOps** — on a fresh cluster
> run the install in [`infra-gitops/base/cert-manager/README.md`](../../infra-gitops/base/cert-manager/README.md)
> first (pinned v1.14.7 + webhook hostNetwork — see that README for why).

| # | Bonus | Implemented as | Show it with |
|---|-------|----------------|--------------|
| 1 | **ArgoCD** | `infra` / `myapp` / `myapp-dev` Applications | `kubectl -n argocd get applications` + the UI |
| 2 | **Zero-downtime + auto-rollback** | `maxUnavailable:0` + ArgoCD selfHeal | `./scripts/demo-rollback.sh` |
| 3 | **Private registry** | `registry:2` on kube-1 (`10.0.9.227:5000`) | image ref on the deploy; `curl …/v2/_catalog` on kube-1 |
| 4 | **Lightweight image** | multi-stage `sample-app/Dockerfile` + `.dockerignore` | the `FROM … AS` stages; `nerdctl images` size on kube-1 |
| 5 | **cert-manager TLS** | self-signed CA `ClusterIssuer` + chart `ingress.tls` | `kubectl get clusterissuer`; `openssl s_client` shows our CA |
| 6 | **MySQL NetworkPolicy** | chart `networkpolicy.yaml` (Calico-enforced) | rogue pod → `Connection timed out` |
| 7 | **RBAC** | `base/rbac` auditor + chart operator | `kubectl auth can-i … --as=<sa>` |

Key per-bonus commands (the scripts run these for you):

```bash
# 3 — private registry (the image comes from our registry, not Docker Hub)
kubectl -n myapp get deploy myapp-myapp \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="myapp")].image}'

# 5 — TLS leaf is issued by our in-cluster CA
echo | openssl s_client -connect <ingress-ip>:443 -servername app.kubequest.local 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName

# 6 — MySQL only reachable by app/backup pods (rogue pod is blocked)
kubectl -n myapp-dev run rogue --rm -i --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"rogue","image":"busybox:1.36","command":["nc","-zvw3","myapp-mysql","3306"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'

# 7 — read-only auditor cannot read secrets or mutate
SA=system:serviceaccount:access-control:cluster-auditor
kubectl auth can-i list pods -A --as=$SA      # yes
kubectl auth can-i get secrets -A --as=$SA    # no
```

**How this differs from the generic plan below:** the CA is self-signed (private
`.local`, not Let's Encrypt); the DB is MySQL (not Postgres) and its policy is
scoped to the DB to avoid the hostNetwork-ingress gotcha; the registry is the
local `registry:2` on kube-1 (not ECR); and **RBAC** (auditor + namespaced
operator) was added on top.

---

## Bonus 1 — ArgoCD (GitOps Automation)

ArgoCD replaces manual `kubectl apply` and gives you a visual UI for GitOps.

### Install
```bash
kubectl create namespace argocd

kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### Expose via Ingress
```yaml
# argocd/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

```bash
kubectl apply -f argocd/ingress.yaml
```

### Get initial admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Install ArgoCD CLI
```bash
brew install argocd   # macOS
# or download from https://github.com/argoproj/argo-cd/releases
```

### Log in
```bash
argocd login argocd.kubequest.local \
  --username admin \
  --password <password> \
  --insecure
```

### Create Application — infra-gitops
```yaml
# argocd/app-infra.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/infra-gitops
    targetRevision: main
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Create Application — app-gitops
```yaml
# argocd/app-myapp.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/app-gitops
    targetRevision: main
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f argocd/app-infra.yaml
kubectl apply -f argocd/app-myapp.yaml
```

> With `automated` sync enabled, any push to your Git repos will automatically trigger a deploy.

---

## Bonus 2 — cert-manager + Let's Encrypt

Add real TLS to all Ingress routes.

### Install cert-manager
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

### Create ClusterIssuer (Let's Encrypt)
```yaml
# cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

```bash
kubectl apply -f cert-manager/cluster-issuer.yaml
```

### Update Ingress to use TLS
```yaml
# Add to any Ingress resource
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - app.yourdomain.com
      secretName: app-tls
  rules:
    - host: app.yourdomain.com
      ...
```

> Let's Encrypt requires a publicly accessible domain. For local testing, use a self-signed issuer instead.

### Self-signed issuer (for local/demo)
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

---

## Bonus 3 — Zero-Downtime Deployment

Ensure rolling updates never drop a single HTTP request.

### Add readiness probes + minReadySeconds to Deployment
```yaml
# In charts/myapp/templates/deployment.yaml
spec:
  minReadySeconds: 10       # wait 10s after pod is ready before shifting traffic
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1           # allow 1 extra pod during rollout
      maxUnavailable: 0     # never reduce below desired count

  template:
    spec:
      containers:
        - name: myapp
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            successThreshold: 1
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
```

### Test zero-downtime during deploy
```bash
# In one terminal — keep sending requests
while true; do
  curl -s -o /dev/null -w "%{http_code}\n" http://app.kubequest.local/
  sleep 0.5
done

# In another terminal — trigger a rolling update
helm upgrade myapp ./charts/myapp --set image.tag=1.0.1 -n myapp

# All responses should be 200 — no 502/503 errors
```

---

## Bonus 4 — Private Registry (AWS ECR)

Push and pull images from a private ECR registry.

### Create ECR repository
```bash
aws ecr create-repository --repository-name kubequest/myapp --region eu-west-1
```

### Build and push image
```bash
# Get login token
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin \
  <account-id>.dkr.ecr.eu-west-1.amazonaws.com

# Build and push
docker build -t kubequest/myapp:1.0.0 .
docker tag kubequest/myapp:1.0.0 \
  <account-id>.dkr.ecr.eu-west-1.amazonaws.com/kubequest/myapp:1.0.0
docker push <account-id>.dkr.ecr.eu-west-1.amazonaws.com/kubequest/myapp:1.0.0
```

### Create imagePullSecret
```bash
aws ecr get-login-password --region eu-west-1 | \
  kubectl create secret docker-registry ecr-secret \
    --docker-server=<account-id>.dkr.ecr.eu-west-1.amazonaws.com \
    --docker-username=AWS \
    --docker-password=$(aws ecr get-login-password --region eu-west-1) \
    --namespace myapp
```

### Reference in Helm chart
```yaml
# values.yaml
image:
  repository: <account-id>.dkr.ecr.eu-west-1.amazonaws.com/kubequest/myapp
  tag: "1.0.0"

imagePullSecrets:
  - name: ecr-secret
```

```yaml
# templates/deployment.yaml
spec:
  imagePullSecrets:
    {{- toYaml .Values.imagePullSecrets | nindent 8 }}
```

---

## Bonus 5 — Network Policies

Restrict pod-to-pod communication to only what is needed.

### Default deny all ingress traffic
```yaml
# network-policies/default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: myapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

### Allow app to receive traffic from ingress controller only
```yaml
# network-policies/allow-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: myapp
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
```

### Allow app to reach database only
```yaml
# network-policies/allow-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-db
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: myapp
      ports:
        - protocol: TCP
          port: 5432
```

```bash
kubectl apply -f network-policies/
```

---

## Bonus 6 — kube-rbac-proxy (Multi-tenant Prometheus/Loki)

Add per-namespace access control to Prometheus metrics.

```bash
# This is an advanced bonus — tackle only if time permits
# Reference: https://github.com/brancz/kube-rbac-proxy
```

---

## Completion Checklist

### Core (required)
- [ ] Phase 1 — Terraform + AWS VMs
- [ ] Phase 2 — Kubernetes cluster (kubeadm)
- [ ] Phase 3 — nginx-ingress, Dashboard, Prometheus, Loki
- [ ] Phase 4 — Helm chart with all best practices
- [ ] Phase 5 — GitOps repos + CI/CD pipeline
- [ ] Phase 6 — OPA policies + Dex auth
- [ ] Phase 7 — All defense scripts tested

### Bonuses
- [x] ArgoCD — automatic GitOps sync (`infra` / `myapp` / `myapp-dev`)
- [x] cert-manager — TLS via self-signed in-cluster CA (app route)
- [x] Zero-downtime — `maxUnavailable:0` + readiness probes (proven by demo-rollback.sh)
- [x] Private registry — `registry:2` on kube-1 (`10.0.9.227:5000`)
- [x] Lightweight image — multi-stage Dockerfile + `.dockerignore`
- [x] Network policy — MySQL locked to app + backup pods (Calico)
- [x] RBAC — least-privilege auditor + per-namespace operator
- [ ] kube-rbac-proxy — multi-tenant observability (not done)
- [ ] TLS on Grafana/Prometheus/Dashboard (needs oauth2 signin URLs reworked to https first)