# KubeQuest — Project Plan
> Sailing Through the Clouds | Epitech

---

## Overview

Design and deploy a fully-equipped Kubernetes cluster on AWS, including management tools, observability, security, and a production-ready application migrated from docker-compose.

---

## Phase 1 — Infrastructure Provisioning (Terraform + AWS)

**Goal:** Get your 4 VMs running and accessible.

- Write Terraform configs to provision 4 EC2 instances (`kube-1`, `kube-2`, `ingress`, `monitoring`)
- Configure security groups (ports 22, 80, 443, 6443), SSH key pairs, shared VPC
- Store Terraform state remotely (S3 bucket)
- Verify SSH access to all machines

---

## Phase 2 — Kubernetes Cluster Bootstrap

**Goal:** A working 2-node cluster.

- Initialize control plane on `kube-1` with `kubeadm init`
- Join `kube-2` with `kubeadm join`
- Install CNI plugin (Flannel or Calico) for pod networking
- Verify with `kubectl get nodes`

---

## Phase 3 — Cluster Tooling (GitOps Repo #1)

**Goal:** Deploy all management components via Kustomize.

### Repository structure
```
infra-gitops/
├── base/
│   ├── nginx-ingress/
│   ├── kubernetes-dashboard/
│   ├── kube-prometheus/
│   └── loki/
└── overlays/
    └── production/
```

### Deployment order
1. **nginx-ingress** — on the `ingress` node (DaemonSet or Deployment with NodeSelector)
2. **Kubernetes Dashboard** — exposed via Ingress rule
3. **kube-prometheus** (Prometheus + Grafana + Alertmanager) — on `monitoring` node
4. **Loki** — on `monitoring` node, with Promtail as a DaemonSet on all nodes

---

## Phase 4 — Application Helm Chart

**Goal:** Convert the docker-compose app into a deployable Helm chart.

- Analyze the docker-compose file and identify all services
- Create a custom Helm chart (`charts/myapp/`) with:
  - Deployment, Service, Ingress, HPA, ConfigMap templates
- Use an official Helm chart for the database (Bitnami PostgreSQL or MySQL)
- Wire services together via `values.yaml` referencing Secrets for credentials

### Best practices to apply inside the chart
- Resource limits and requests on every container
- Kubernetes Secrets for all sensitive data
- Recommended labels (`app.kubernetes.io/name`, `app.kubernetes.io/version`, etc.)
- Multiple replicas + pod anti-affinity for the app
- PersistentVolumeClaim for the database
- CronJob for database backups

---

## Phase 5 — Application GitOps Repo (#2)

**Goal:** Deploy the app declaratively with automation.

```
app-gitops/
├── base/
│   ├── app/
│   └── database/
└── overlays/
    └── production/
```

### CI/CD Pipeline
- Build and push Docker image on merge
- Run `helm upgrade --install` or `kustomize apply`
- Verify deployment health with `kubectl rollout status`
- Trigger automatic rollback with `kubectl rollout undo` on failure

---

## Phase 6 — Security Layer

**Goal:** OPA validating webhook + authentication.

### OPA Gatekeeper
- Install via Helm
- Write ConstraintTemplates to enforce:
  - All pods must have resource limits
  - No `latest` image tags allowed
- Register as ValidatingWebhookConfiguration

### Dex + oauth-proxy
- Deploy Dex as OIDC identity provider
- Configure with static users or GitHub/Google connector
- Put oauth-proxy in front of Dashboard, Grafana, and Prometheus Ingress routes

---

## Phase 7 — Defense Preparation

**Goal:** Make the live demo smooth and impressive.

### Scripts to prepare
| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | Provision cluster from scratch |
| `deploy-infra.sh` | Deploy all tooling via Kustomize/Helm |
| `deploy-app.sh` | Deploy the application |
| `load-test.sh` | Hammer the app to trigger HPA auto-scaling |
| `break-deployment.sh` | Deploy a bad image to demo rollback |

### Intentional failure endpoints (for demo)
- `/leak` — allocates memory progressively
- `/cpu` — spins a CPU loop

---

## Phase 8 — Bonuses

Priority order for maximum demo impact:

1. **ArgoCD** — fully automatic GitOps, visual UI
2. **cert-manager + Let's Encrypt** — real TLS on all Ingress routes
3. **Zero-downtime deployment** — readiness probes + `minReadySeconds`
4. **Private registry** — push images to ECR, configure `imagePullSecrets`
5. **kube-rbac-proxy** — multi-tenant Prometheus and Loki
6. **Network policies** — reinforce network access

---

## Suggested Timeline

| Week | Focus |
|------|-------|
| 1 | Phases 1 & 2 — Terraform + cluster up |
| 2 | Phase 3 — All cluster tooling deployed |
| 3 | Phases 4 & 5 — Helm chart + GitOps for app |
| 4 | Phase 6 — OPA + Dex auth |
| 5 | Phase 7 — Defense scripts + polish |
| 6 | Phase 8 — Bonuses + documentation |

---

## Delivery Checklist

- [ ] All configs pushed to Git repos
- [ ] Documentation written (setup steps + commands)
- [ ] Both GitOps repos functional
- [ ] All best practices applied (limits, secrets, labels, replicas, PVC, backups)
- [ ] OPA policies enforced
- [ ] Authentication working on all tools
- [ ] Defense scripts tested end-to-end
- [ ] Fresh cluster deploy rehearsed at least twice