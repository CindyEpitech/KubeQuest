# KubeQuest — Defense Guide

How every requirement and bonus from `kubequest.txt` is implemented, and the
exact step-by-step way to **prove each one to the teacher**.

> **Conventions used below**
> - Ingress hosts resolve through `/etc/hosts` → ingress node IP:
>   `app.kubequest.local`, `app-dev.kubequest.local`, `grafana.kubequest.local`,
>   `prometheus.kubequest.local`, `dashboard.kubequest.local`, `dex.kubequest.local`.
> - Namespaces: prod app = `myapp`, dev app = `myapp-dev`, infra = `default` / component namespaces.
> - GitOps: ArgoCD apps `infra` + `myapp` track **main**, `myapp-dev` tracks **develop**.
> - All demo scripts live in `scripts/` and are `[Enter]`-paced so you can talk over them.

---

## 0. The defense flow (what the teacher asked for)

The spec's "Defense" section asks for four things. Map them to these scripts:

| Defense requirement | How you prove it |
|---|---|
| 1. Start a fresh cluster in the cloud | `./scripts/bootstrap.sh <user>` |
| 2. Deploy with only `kubectl apply` / `kustomize` / `helm` | ArgoCD bootstrap + `kubectl apply -k` / `helm` (§ GitOps) |
| 3. Demo auto-scaling with live load | `./scripts/load-test.sh` → watch HPA (§ Redundancy/HPA) |
| 4. Full deploy + broken deploy with automatic rollback | `./scripts/demo-rollback.sh` |
| Bonuses showcase | `./scripts/demo-bonuses.sh` |

**Suggested running order on the day:** bootstrap → apply infra (Kustomize) → ArgoCD
takes over → `demo-rollback.sh` → `load-test.sh` → `demo-bonuses.sh`.

---

# PART 1 — Mandatory requirements

## 1.1 Internal load balancer / ingress (nginx-ingress) ✅

**Implementation.** ingress-nginx controller runs on the dedicated `ingress`
node (`hostNetwork`, `dnsPolicy: ClusterFirstWithHostNet`). In-tree ingresses for
each tool live in `infra-gitops/base/*/ingress.yaml`; the chart exposes the app via
`infra-gitops/charts/myapp/templates/ingress.yaml` (`className: nginx`).

**Prove it.**
```bash
kubectl get pods -n ingress-nginx -o wide          # controller on the ingress node
kubectl get ingress -A                             # every tool + app has a host
curl -I http://app.kubequest.local                 # 200 OK through the LB
```

## 1.2 Dashboard (kubernetes-dashboard) ✅

**Implementation.** `infra-gitops/base/kubernetes-dashboard/` — `admin-user.yaml`
(SA + ClusterRoleBinding) and `ingress.yaml` at `dashboard.kubequest.local`.

**Prove it.**
```bash
kubectl -n kubernetes-dashboard create token admin-user   # login token
# Browser: https://dashboard.kubequest.local → paste token → manage workloads live
```

## 1.3 Monitoring stack (kube-prometheus) ✅

**Implementation.** kube-prometheus-stack (Prometheus + Grafana + Alertmanager) on
the `monitoring` node. Repo adds ingresses, an alert rule
(`alert-memory.yaml`), a cert-manager ServiceMonitor, and **6 Grafana dashboards**
in `infra-gitops/base/kube-prometheus/dashboards/` (app, infra, logs, capacity,
ingress, certificates).

**Prove it.**
```bash
kubectl get pods -n monitoring
# Browser: http://grafana.kubequest.local  → Dashboards → open "App" + "Infra"
# Browser: http://prometheus.kubequest.local → Status/Targets → all UP
```
Show a metric moving: run `load-test.sh` in another terminal and watch CPU climb on the App dashboard.

## 1.4 GitOps repo with reusable manifests (kustomize) ✅

**Implementation.** `infra-gitops/` is the GitOps tree: `base/` per component +
`overlays/production/kustomization.yaml` aggregating them. ArgoCD `infra` app syncs
this overlay.

**Prove it.**
```bash
kustomize build infra-gitops/overlays/production | head      # renders cleanly
kubectl apply -k infra-gitops/overlays/production            # one command, whole infra
```

## 1.5 Logging stack (loki) ✅

**Implementation.** Loki on the `monitoring` node; `base/loki/grafana-datasource.yaml`
wires it into Grafana, plus a Logs dashboard.

**Prove it.**
```bash
# Browser: Grafana → Explore → datasource "Loki" → query: {namespace="myapp"}
# Show live app logs; or open the "Logs" dashboard.
```

## 1.6 App Helm chart + official DB chart ✅

**Implementation.** `infra-gitops/charts/myapp/` is the application Helm chart
(deployment, service, ingress, hpa, configmap, secret, pvc, backup cronjob,
networkpolicy, rbac). MySQL is provided by the official image/chart pattern via
`templates/mysql.yaml` (DB kept outside the app release in prod).

**Prove it.**
```bash
helm template myapp infra-gitops/charts/myapp -f infra-gitops/charts/myapp/values-production.yaml | head
helm list -A            # app release present
kubectl get pods -n myapp
```

## 1.7 App GitOps deploy + automation ✅

**Implementation.** Push-to-deploy: `scripts/deploy.sh` builds on kube-1, bumps the
tag in `values-dev.yaml`, pushes to **develop** → ArgoCD `myapp-dev` rolls it out.
Merging develop→main fires `.github/workflows/promote.yml`, which opens a PR bumping
`values-production.yaml` → ArgoCD `myapp` rolls out prod. CI (`ci.yml`) +
`sync-develop.yml` round it out.

**Prove it.**
```bash
argocd app list                       # infra / myapp / myapp-dev all Synced+Healthy
./scripts/deploy.sh <user>            # the git push IS the deploy
# Show the GitHub Actions tab: ci → promote → sync running on push/merge.
```

---

# PART 2 — Best practices

## 2.1 Resource limits & requests ✅

**Implementation.** Every container sets requests+limits (`values.yaml` `resources:`,
init container, backup job). **Enforced** by the OPA constraint
`gatekeeper/constraints/require-resources.yaml` — pods without them are rejected.

**Prove it.**
```bash
kubectl get deploy -n myapp -o jsonpath='{..resources}'; echo
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-no-resources-pod.yaml
#   → DENIED by gatekeeper (admission webhook rejects it)
```

## 2.2 Secrets ✅

**Implementation.** `templates/secret.yaml` (app key, DB password, root password).
In prod, `secret.create: false` — secrets are pre-created in the namespace, never
committed (see `infra-gitops/argocd/README.md`).

**Prove it.**
```bash
kubectl get secret -n myapp
kubectl get deploy -n myapp -o yaml | grep -A3 secretKeyRef    # injected via env, not plaintext
git grep -i password infra-gitops/charts/myapp/values-production.yaml   # nothing sensitive in git
```

## 2.3 Labels (k8s recommended) ✅

**Implementation.** `templates/_helpers.tpl` emits the recommended
`app.kubernetes.io/*` label set on every object.

**Prove it.**
```bash
kubectl get all -n myapp --show-labels | head
kubectl get pods -n myapp -l app.kubernetes.io/name=myapp
```

## 2.4 Redundancy — replicas + affinity ✅

**Implementation.** `deployment.yaml`: `replicaCount: 2`, **podAntiAffinity**
(spread across hosts via `topologyKey: kubernetes.io/hostname`) + **nodeAffinity**
(keep app off ingress/monitoring nodes). HPA scales 2→6 on 70% CPU.

**Prove it (this is also defense requirement #3 — auto-scaling).**
```bash
kubectl get pods -n myapp -o wide          # 2 pods, different nodes
kubectl get hpa -n myapp
./scripts/load-test.sh                      # hammer /cpu
watch kubectl get hpa,pods -n myapp         # replicas climb toward 6, then back down
```

## 2.5 Persistent storage + backup ✅

**Implementation.** `templates/pvc.yaml` (MySQL data) + `templates/cronjob-backup.yaml`
(daily `0 2 * * *` mysqldump to a dedicated backup PVC).

**Prove it.**
```bash
kubectl get pvc -n myapp
kubectl get cronjob -n myapp
kubectl create job -n myapp --from=cronjob/<backup-cronjob> manual-backup   # run it now
kubectl logs -n myapp job/manual-backup                                     # dump succeeded
```

---

# PART 3 — Security & control

## 3.1 Validating webhook (OPA / Gatekeeper) ✅

**Implementation.** `infra-gitops/base/gatekeeper/` installs Gatekeeper + two
ConstraintTemplates/Constraints: **require-resources** and **disallow-latest-tag**.
The webhook is patched **fail-closed** (`validating-webhook-fail.yaml`).

**Prove it.**
```bash
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml       # DENIED (:latest)
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-no-resources-pod.yaml # DENIED (no limits)
kubectl get constraints
```

## 3.2 Authentication (Dex + oauth2-proxy) ✅

**Implementation.** `infra-gitops/base/auth/` — Dex as OIDC provider
(`dex.kubequest.local`) + oauth2-proxy guarding the tool ingresses.

**Prove it.**
```bash
# Browser: open http://grafana.kubequest.local (or another protected tool)
#   → redirected to Dex login → authenticate → bounced back in.
kubectl get pods -n auth
```

---

# PART 4 — Infrastructure & fresh-cluster bootstrap

**Implementation.** `scripts/bootstrap.sh` turns 4 freshly-launched AWS VMs
(`kube-1`, `kube-2`, `ingress`, `monitoring`) into a kubeadm cluster: preps nodes,
`kubeadm init` on kube-1, CNI, joins the others, removes the control-plane taint,
labels `role=ingress`/`role=monitoring`, copies kubeconfig to your laptop.

**Prove it (defense requirement #1 + #2).**
```bash
./scripts/bootstrap.sh <user>              # fresh 4-node cluster from scratch
kubectl get nodes -o wide                  # 4 nodes Ready, roles labeled
kubectl apply -k infra-gitops/overlays/production   # deploy infra with kustomize
```
> ℹ️ **CNI:** `bootstrap.sh` installs **Calico** (`v3.27.5`, pod CIDR
> `192.168.0.0/16`), matching the long-lived cluster. Calico enforces
> NetworkPolicy, so a freshly-bootstrapped cluster can demo the NetworkPolicy
> bonus too. Override the version with `CALICO_VERSION=...` if you bump Kubernetes.

---

# PART 5 — Bonuses

Run `./scripts/demo-bonuses.sh` for a narrated walkthrough of 1–6 below. Zero-downtime
+ automatic rollback (7) has its own script.

## 5.1 cert-manager / TLS encryption ✅

**Implementation.** `base/cert-manager/cluster-issuer.yaml` builds a self-signed CA
chain (Let's Encrypt can't validate `.local`): `selfsigned-bootstrap` → `kubequest-ca`
(CA cert) → `kubequest-ca` ClusterIssuer signs per-host leaf certs via ingress-shim.
Prod app turns it on (`values-production.yaml` → `ingress.tls.enabled: true`).

**Prove it.**
```bash
kubectl get clusterissuer
kubectl get certificate -A
curl -vk https://app.kubequest.local 2>&1 | grep -E 'issuer|subject'   # cert from KubeQuest CA
```

## 5.2 ArgoCD GitOps management ✅

**Implementation.** `infra-gitops/argocd/` — app-of-apps managing `infra`, `myapp`,
`myapp-dev`, all `prune: true` + `selfHeal: true`.

**Prove it.**
```bash
argocd app list                        # all Synced/Healthy
# Browser: ArgoCD UI → show the dependency tree reconciling.
```

## 5.3 Lightweight Docker image ✅

**Implementation.** `sample-app/Dockerfile` is **multi-stage**: `composer:2` builder
(`--no-dev`, optimized autoloader) → slim `php:8.2-apache` runtime with only
`pdo_mysql`. No git/unzip/compose/dev-deps in the final image.

**Prove it.**
```bash
docker images <registry>/myapp           # compare size vs. a single-stage build
docker history <registry>/myapp | head   # no build tooling layers in runtime
```

## 5.4 Private registry ✅

**Implementation.** Images pushed to and pulled from the in-cluster registry at
`10.0.9.227:5000` (`values-production.yaml` `image.repository`).

**Prove it.**
```bash
grep repository infra-gitops/charts/myapp/values-production.yaml   # 10.0.9.227:5000/myapp
kubectl describe pod -n myapp <pod> | grep -i image                # pulled from private registry
```

## 5.5 RBAC / access permissions ✅

**Implementation.** `base/rbac/cluster-auditor.yaml` — a least-privilege auditor
that **cannot read secrets**. Chart adds a namespaced operator SA/Role/RoleBinding
(`rbac.create: true` in prod), additive (grants a scoped identity, restricts no one).

**Prove it.**
```bash
kubectl auth can-i get secrets --as=system:serviceaccount:<ns>:cluster-auditor   # no
kubectl auth can-i list pods   --as=system:serviceaccount:<ns>:cluster-auditor   # yes
```

## 5.6 NetworkPolicy (network hardening) ⚠️ written, toggle off

**Implementation.** `charts/myapp/templates/networkpolicy.yaml` — default-deny
ingress to MySQL, allowing only app + backup pods on 3306. Calico enforces it.
Currently `networkPolicy.enabled: false` everywhere (validate on dev, then flip).

**Prove it (after enabling on dev/prod).**
```bash
kubectl get networkpolicy -n myapp
# Allowed: app pod → mysql:3306 succeeds
# Denied: a random pod → mysql:3306 times out
kubectl run probe --rm -it --image=busybox -n myapp -- nc -zv <mysql> 3306   # blocked
```

## 5.7 Zero-downtime deploy + automatic rollback ✅ (the headline demo)

**Implementation.** Deployment uses `maxUnavailable: 0` + readiness probe (broken
image never goes Ready, old pods keep serving). ArgoCD `selfHeal: true` reverts any
drift from git **with no human running a rollback**.

**Prove it (defense requirement #4).**
```bash
./scripts/demo-rollback.sh
#   1. healthy start (pods Running, ArgoCD Synced)
#   2. background prober hits app every 1s, tallying success/fail
#   3. inject bogus image → new pod ImagePullBackOff, old pod stays Running
#   4. ArgoCD selfHeal reverts to the git tag automatically
#   5. result box: Rollback AUTOMATIC, HTTP during deploy N/N OK, 0 failed
```
> ⚠️ `AUTO=1` genuinely breaks+heals prod (not a dry run). The interactive default
> pauses before each destructive step — use that in front of the teacher.

---

# Quick-reference: one command per requirement

```bash
# Infra up
kubectl get nodes -o wide && kubectl get pods -A | grep -vE 'Running|Completed'
# Ingress / LB
kubectl get ingress -A && curl -I http://app.kubequest.local
# Monitoring + logging       → grafana.kubequest.local / prometheus.kubequest.local
# Dashboard                  → dashboard.kubequest.local (token: kubectl -n kubernetes-dashboard create token admin-user)
# GitOps                     → argocd app list
# Limits/secrets/labels      → kubectl get deploy -n myapp -o yaml
# Redundancy + HPA           → kubectl get pods,hpa -n myapp -o wide ; ./scripts/load-test.sh
# Storage + backup           → kubectl get pvc,cronjob -n myapp
# OPA webhook                → kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml  (DENIED)
# Auth                       → open a tool ingress → Dex login
# Rollback demo              → ./scripts/demo-rollback.sh
# Bonuses                    → ./scripts/demo-bonuses.sh
```
