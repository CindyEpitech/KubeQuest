# KubeQuest — Phases Overview

A summary of every phase: what it does, what you deploy, and what you end up with.

---

## Phase 1 — Infrastructure
**File:** [PHASE_1_INFRASTRUCTURE.md](./PHASE_1_INFRASTRUCTURE.md)
**Tools:** Terraform, AWS EC2

Provision all 4 VMs from scratch on AWS using Terraform.
No infrastructure is provided — you write the Terraform code yourself.

| VM | Role | Type |
|----|------|------|
| `kube-1` | Control plane + worker | t3.medium |
| `kube-2` | Worker | t3.medium |
| `ingress` | Handles all external HTTP/HTTPS traffic | t3.small |
| `monitoring` | Runs Prometheus, Grafana, Loki | t3.large |

**You end up with:** 4 running EC2 instances with SSH access, a shared security group, and public IPs.

---

## Phase 2 — Kubernetes Cluster Bootstrap
**File:** [PHASE_2_CLUSTER_BOOTSTRAP.md](./PHASE_2_CLUSTER_BOOTSTRAP.md)
**Tools:** kubeadm, containerd, Flannel, Amazon Linux 2023

Turn the 4 raw VMs into a working Kubernetes cluster.

Steps:
1. Install containerd, kubeadm, kubelet, kubectl on all 4 VMs (using `yum`, not `apt`)
2. Initialize the control plane on `kube-1` with `kubeadm init`
3. Install Flannel as the CNI plugin
4. Join `kube-2`, `ingress`, and `monitoring` as worker nodes
5. Remove the control-plane taint so `kube-1` can also run pods
6. Label nodes (`role=ingress`, `role=monitoring`) so pods schedule in the right places

**You end up with:** A 4-node cluster where all nodes are `Ready` and `kubectl get nodes` works.

### Phase 2 — WSL Access
**File:** [PHASE_2_WSL.md](./PHASE_2_WSL.md)

Configure `kubectl` on your local WSL machine so you can run cluster commands without SSH-ing into kube-1.

Key points:
- Copy the kubeconfig from kube-1 via `scp`
- Replace the private IP with the public IP of kube-1
- Disable TLS verification (`--insecure-skip-tls-verify`) because the API server certificate only covers private IPs
- After every VM reboot, update the IP in kubeconfig (public IP changes each time)

**You end up with:** `kubectl` working from WSL on your laptop.

---

## Phase 3 — Cluster Tooling
**File:** [PHASE_3_CLUSTER_TOOLING.md](./PHASE_3_CLUSTER_TOOLING.md)
**Tools:** Helm, nginx-ingress, Kubernetes Dashboard, kube-prometheus-stack, Loki, Kustomize

Deploy all cluster management components into the cluster using a Kustomize-based `infra-gitops` repository.

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| nginx-ingress | `ingress-nginx` | Routes external HTTP/HTTPS to services — runs on the `ingress` node with `hostNetwork=true` |
| Kubernetes Dashboard | `kubernetes-dashboard` | Web UI to visualize cluster resources |
| kube-prometheus-stack | `monitoring` | Prometheus (metrics), Grafana (dashboards), Alertmanager — runs on the `monitoring` node |
| Loki + Promtail | `monitoring` | Centralized log aggregation — Promtail runs as a DaemonSet on all nodes |

**Key gotchas encountered:**
- AWS Security Group must allow "All traffic" between nodes (same security group) — without this, Calico breaks pod-to-pod networking and you get 504 errors
- nginx-ingress must use `hostNetwork=true` + `DaemonSet` to bind directly on ports 80/443
- CoreDNS must be redirected to `8.8.8.8` instead of the AWS DNS (`10.0.0.2`), which Calico blocks
- Do not create a custom Grafana datasource ConfigMap for Loki — `loki-stack` already creates one, adding a second causes a crash

**You end up with:** Dashboard at `dashboard.kubequest.local`, Grafana at `grafana.kubequest.local`, Prometheus at `prometheus.kubequest.local`, all accessible via the ingress node's public IP.

---

## Phase 4 — Private Registry
**File:** [PHASE_4_REGISTRY.md](./PHASE_4_REGISTRY.md)
**Tools:** nerdctl, buildkit, registry:2

Run a private container registry directly on kube-1, accessible by all nodes over the private AWS network.

- `registry:2` runs as a nerdctl container on kube-1, listening on port 5000
- `nerdctl` + `buildkitd` are used to build images (Docker is not installed)
- All 4 nodes are configured to pull from `10.0.9.227:5000` without TLS
- Workflow: copy source from WSL via `scp` → build on kube-1 → push to registry

**You end up with:** A working private registry at `10.0.9.227:5000` that all cluster nodes can pull from.

---

## Phase 4 — Application Helm Chart
**File:** [PHASE_4_HELM_CHART.md](./PHASE_4_HELM_CHART.md)
**Tools:** Helm, Laravel PHP 8.2, MySQL 8.0, local-path-provisioner

Package and deploy the application (a Laravel PHP app + MySQL database) as a Helm chart.

The chart (`charts/myapp/`) contains:

| Template | What it does |
|----------|-------------|
| `deployment.yaml` | Runs 2 Laravel app replicas with anti-affinity |
| `mysql.yaml` | MySQL 8.0 official image — Deployment + Service + PVC |
| `secret.yaml` | APP_KEY + DB credentials |
| `configmap.yaml` | Non-sensitive env vars |
| `ingress.yaml` | Exposes the app via nginx-ingress at `app.kubequest.local` |
| `hpa.yaml` | Auto-scales 2→6 replicas based on CPU |
| `cronjob-backup.yaml` | Daily `mysqldump`, keeps 7 backups |
| `pvc.yaml` | Backup storage |

**Key gotchas encountered:**
- Bitnami MySQL not usable — replaced with official `mysql:8.0` image via a custom `mysql.yaml`; always pass `--set mysql.enabled=false`
- No default StorageClass — install `local-path-provisioner` from Rancher
- CoreDNS DNS fix required (done in Phase 3)
- Readiness probe path changed from `/up` to `/` (Laravel default returns 404 on `/up`)
- Laravel migrations must be run manually after first deploy: `kubectl exec -- php artisan migrate --force`

**You end up with:** The Laravel app running at `http://app.kubequest.local` with a persistent MySQL database, auto-scaling, and daily backups.

---

## Phase 5 — Application GitOps
**File:** [PHASE_5_APP_GITOPS.md](./PHASE_5_APP_GITOPS.md)
**Tools:** Helm, nerdctl, WSL

Deploy and update the application declaratively using a repeatable GitOps loop.

Every update follows the same cycle:
```
WSL → scp source to kube-1
kube-1 → nerdctl build + push to 10.0.9.227:5000
WSL → helm upgrade with new image tag
```

Key practices:
- Always increment the image tag (`v0.1.0` → `v0.1.1`) — never reuse a tag
- Use `--wait --timeout 5m` on `helm upgrade` so failures are detected immediately
- Rollback via `helm rollback myapp` or `kubectl rollout undo deployment/myapp-myapp`
- Run `artisan migrate --force` after schema changes

**You end up with:** A fully repeatable update and rollback workflow for the application.

---

## Phase 6 — Security Layer
**File:** [PHASE_6_SECURITY.md](./PHASE_6_SECURITY.md)
**Tools:** OPA Gatekeeper, Dex, oauth2-proxy

Add two security layers to the cluster.

### OPA Gatekeeper — Admission Control
Enforces policies on every resource created in the cluster:
- **Require resource limits** — any pod without CPU/memory limits is rejected
- **Disallow `:latest` tags** — any pod using `latest` or no tag is rejected

### Dex + oauth2-proxy — Authentication
Puts an OIDC login screen in front of Dashboard, Grafana, and Prometheus:
- Dex acts as the identity provider (local user `admin@kubequest.local`)
- oauth2-proxy sits in front of each protected service and redirects unauthenticated requests to Dex
- nginx-ingress forwards auth checks to oauth2-proxy via annotations

**You end up with:** Policy enforcement on all new workloads, and a login page protecting all monitoring/admin UIs.

---

## Phase 7 — Defense Preparation
**File:** [PHASE_7_DEFENSE.md](./PHASE_7_DEFENSE.md)

Prepare everything for the live demo so no commands are typed from scratch.

| Script | What it demonstrates |
|--------|---------------------|
| `bootstrap.sh` | Full cluster provisioning from zero |
| `deploy-infra.sh` | All tooling deployed in one command |
| `deploy-app.sh` | Application deployed live |
| `load-test.sh` | HPA auto-scaling triggered under load |
| `break-deployment.sh` | Broken deploy followed by automatic rollback |

**Demo run order:**
1. `bootstrap.sh` — fresh cluster live
2. `deploy-infra.sh` — all tooling deployed
3. `deploy-app.sh` — app live
4. Grafana — show dashboards
5. `load-test.sh` — HPA scaling in real time
6. `/cpu` endpoint — CPU spike visible in Grafana
7. `break-deployment.sh` — rollback demo
8. OPA — show pod rejected for `:latest` tag
9. Dex — show login screen on protected URL

**You end up with:** A rehearsed, script-driven demo that runs reliably under pressure.

---

## Phase 8 — Bonuses
**File:** [PHASE_8_BONUSES.md](./PHASE_8_BONUSES.md)

Optional features to add after the core is complete and tested.

| Bonus | What it adds |
|-------|-------------|
| **ArgoCD** | GitOps automation — auto-deploys on every Git push, with a visual UI |
| **cert-manager** | Real TLS on all Ingress routes (Let's Encrypt or self-signed) |
| **Zero-downtime deploys** | `maxUnavailable: 0` + readiness probes — no dropped requests during rolling updates |
| **AWS ECR** | Push/pull images from a private AWS ECR registry instead of the local one |
| **Network Policies** | Default deny all, then allowlist only necessary pod-to-pod traffic |
| **kube-rbac-proxy** | Per-namespace access control on Prometheus metrics (advanced) |

---

## Full Dependency Chain

```
Phase 1 — AWS VMs exist
    └── Phase 2 — Kubernetes cluster running
            └── Phase 2 WSL — kubectl works from laptop
            └── Phase 3 — nginx-ingress + Dashboard + Prometheus + Loki
                    └── Phase 4 Registry — private registry on kube-1
                    └── Phase 4 Helm Chart — Laravel app deployed
                            └── Phase 5 — GitOps update/rollback loop
                                    └── Phase 6 — OPA policies + Dex auth
                                            └── Phase 7 — Demo scripts
                                                    └── Phase 8 — Bonuses
```