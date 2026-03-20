# KubeQuest — Phase 6: Security Layer
> OPA Gatekeeper | Dex | oauth2-proxy

---

## Overview

Add two security layers to the cluster:
1. **OPA Gatekeeper** — a validating webhook that enforces policies on all resource creation
2. **Dex + oauth2-proxy** — OIDC-based authentication in front of Dashboard, Grafana, and Prometheus

---

## Part 1 — OPA Gatekeeper

### Install via Helm

```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update

kubectl create namespace gatekeeper-system

helm install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --set replicas=1
```

### Verify
```bash
kubectl get pods -n gatekeeper-system
# Should show: gatekeeper-controller-manager and gatekeeper-audit pods
```

---

### Policy 1 — Require Resource Limits on All Pods

#### ConstraintTemplate
```yaml
# opa/templates/require-resource-limits.yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: requireresourcelimits
spec:
  crd:
    spec:
      names:
        kind: RequireResourceLimits
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package requireresourcelimits

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.cpu
          msg := sprintf("Container '%v' must define CPU limits", [container.name])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.memory
          msg := sprintf("Container '%v' must define memory limits", [container.name])
        }
```

#### Constraint
```yaml
# opa/constraints/require-resource-limits.yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RequireResourceLimits
metadata:
  name: require-resource-limits
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
```

```bash
kubectl apply -f opa/templates/require-resource-limits.yaml
kubectl apply -f opa/constraints/require-resource-limits.yaml
```

---

### Policy 2 — Disallow Latest Image Tags

#### ConstraintTemplate
```yaml
# opa/templates/disallow-latest-tag.yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: disallowlatesttag
spec:
  crd:
    spec:
      names:
        kind: DisallowLatestTag
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package disallowlatesttag

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          endswith(container.image, ":latest")
          msg := sprintf("Container '%v' must not use the 'latest' image tag", [container.name])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not contains(container.image, ":")
          msg := sprintf("Container '%v' must specify an explicit image tag", [container.name])
        }
```

#### Constraint
```yaml
# opa/constraints/disallow-latest-tag.yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: DisallowLatestTag
metadata:
  name: disallow-latest-tag
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces:
      - kube-system
      - gatekeeper-system
```

```bash
kubectl apply -f opa/templates/disallow-latest-tag.yaml
kubectl apply -f opa/constraints/disallow-latest-tag.yaml
```

---

### Test OPA Policies

```bash
# This should be REJECTED — no resource limits
kubectl run test-no-limits --image=nginx:1.25 -n myapp

# This should be REJECTED — latest tag
kubectl run test-latest --image=nginx:latest --limits='cpu=100m,memory=128Mi' -n myapp

# This should be ALLOWED — proper tag + limits
kubectl run test-ok --image=nginx:1.25 \
  --limits='cpu=100m,memory=128Mi' \
  --requests='cpu=50m,memory=64Mi' \
  -n myapp
```

### Check policy violations
```bash
kubectl get constraints
kubectl describe requireresourcelimits require-resource-limits
kubectl describe disallowlatesttag disallow-latest-tag
```

---

## Part 2 — Dex (OIDC Identity Provider)

### Install via Helm

```bash
helm repo add dex https://charts.dexidp.io
helm repo update

kubectl create namespace dex
```

### Dex values.yaml

```yaml
# dex/values.yaml
config:
  issuer: http://dex.kubequest.local

  storage:
    type: kubernetes
    config:
      inCluster: true

  web:
    http: 0.0.0.0:5556

  staticClients:
    - id: oauth2-proxy
      redirectURIs:
        - http://dashboard.kubequest.local/oauth2/callback
        - http://grafana.kubequest.local/oauth2/callback
        - http://prometheus.kubequest.local/oauth2/callback
      name: oauth2-proxy
      secret: oauth2-proxy-secret

  staticPasswords:
    - email: admin@kubequest.local
      hash: "$2y$10$IuEKK5j5ogY7AHJF5MurXeR6i1T0KRmpJTXXBHVJ4OVo7mqCH4f2S"
      # Password: admin123 (bcrypt hash)
      username: admin
      userID: "admin-id-001"
```

> Generate a new bcrypt hash: `htpasswd -bnBC 10 "" yourpassword | tr -d ':\n'`

### Install Dex
```bash
helm install dex dex/dex \
  --namespace dex \
  --values dex/values.yaml
```

### Expose Dex via Ingress
```yaml
# dex/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dex
  namespace: dex
spec:
  ingressClassName: nginx
  rules:
    - host: dex.kubequest.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dex
                port:
                  number: 5556
```

```bash
kubectl apply -f dex/ingress.yaml
```

---

## Part 3 — oauth2-proxy

Deploy one oauth2-proxy per protected service (Dashboard, Grafana, Prometheus), or a single shared instance.

### Install via Helm

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo update

kubectl create namespace oauth2-proxy
```

### oauth2-proxy values.yaml

```yaml
# oauth2-proxy/values.yaml
config:
  clientID: oauth2-proxy
  clientSecret: oauth2-proxy-secret
  cookieSecret: "a-random-32-char-secret-here!!"  # Must be 16, 24, or 32 chars

extraArgs:
  provider: oidc
  oidc-issuer-url: http://dex.kubequest.local
  email-domain: "*"
  upstream: http://kubernetes-dashboard.kubernetes-dashboard.svc.cluster.local:443
  ssl-upstream-insecure-skip-verify: "true"
  http-address: 0.0.0.0:4180
  redirect-url: http://dashboard.kubequest.local/oauth2/callback
  cookie-secure: "false"

resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "200m"
    memory: "128Mi"
```

```bash
helm install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace oauth2-proxy \
  --values oauth2-proxy/values.yaml
```

### Update Dashboard Ingress with auth

```yaml
# Update base/kubernetes-dashboard/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "http://dashboard.kubequest.local/oauth2/start"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
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

### Update Grafana and Prometheus Ingress the same way

Add these annotations to both Grafana and Prometheus Ingress resources:

```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth"
  nginx.ingress.kubernetes.io/auth-signin: "http://<service>.kubequest.local/oauth2/start"
```

---

## Local DNS

Add to `/etc/hosts`:

```
<ingress-public-ip>  dex.kubequest.local
<ingress-public-ip>  dashboard.kubequest.local
<ingress-public-ip>  grafana.kubequest.local
<ingress-public-ip>  prometheus.kubequest.local
```

---

## Test Authentication End-to-End

1. Open http://grafana.kubequest.local — should redirect to Dex login
2. Log in with `admin@kubequest.local` / `admin123`
3. Should redirect back to Grafana, now authenticated
4. Repeat for Dashboard and Prometheus

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| OPA rejecting system pods | Check `excludedNamespaces` in constraints |
| Dex not reachable | Check pod logs: `kubectl logs -n dex <pod>` |
| oauth2-proxy redirect loop | Check `redirect-url` matches Dex `redirectURIs` |
| Cookie secret error | Ensure it is exactly 16, 24, or 32 characters |
| Login fails | Verify bcrypt hash with `htpasswd` |

---

## Next Step

Once OPA policies are enforced and authentication is working, proceed to:
**[Phase 7 — Defense Preparation](./PHASE_7_DEFENSE.md)**