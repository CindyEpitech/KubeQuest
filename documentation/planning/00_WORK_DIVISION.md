# KubeQuest — Work Division
> 2-person team split

---

## Person A — Infrastructure & Observability

You own everything related to the cluster foundation and visibility.

### Phase 1 & 2 — Terraform + Cluster Bootstrap
- [ ] Write all Terraform configs (VPC, EC2, security groups, SSH keys)
- [ ] Bootstrap the cluster with `kubeadm` on both nodes
- [ ] Install the CNI plugin (Flannel or Calico)
- [ ] Verify node connectivity with `kubectl get nodes`

### Phase 3 — Monitoring & Logging
- [ ] Deploy kube-prometheus on the `monitoring` node
  - Prometheus, Grafana, Alertmanager
- [ ] Deploy Loki on the `monitoring` node
- [ ] Deploy Promtail as a DaemonSet across all nodes
- [ ] Configure Grafana dashboards for cluster and app metrics

### Phase 6 — OPA Gatekeeper
- [ ] Install OPA Gatekeeper via Helm
- [ ] Write ConstraintTemplates and Constraints:
  - All pods must define resource limits
  - No `latest` image tags
- [ ] Register and test the ValidatingWebhookConfiguration

### Phase 7 — Defense Scripts
- [ ] `bootstrap.sh` — full cluster provisioning from scratch
- [ ] `deploy-infra.sh` — deploys all tooling via Kustomize/Helm
- [ ] `load-test.sh` — triggers HPA auto-scaling demo
- [ ] Prepare Grafana dashboard for live demo
- [ ] Document all infra setup steps

---

## Person B — Application & GitOps

You own everything related to deploying and managing the actual application.

### Phase 3 — Ingress & Dashboard
- [ ] Deploy nginx-ingress on the `ingress` node
- [ ] Deploy Kubernetes Dashboard and expose via Ingress
- [ ] Set up all Ingress rules for every service (Dashboard, Grafana, Prometheus, app)

### Phase 4 & 5 — Helm Chart + GitOps
- [ ] Analyze the docker-compose app and identify all services
- [ ] Create custom Helm chart (`charts/myapp/`) with:
  - Deployment, Service, Ingress, HPA, ConfigMap
  - Resource limits/requests
  - Kubernetes Secrets for credentials
  - Proper labels on all resources
  - Multiple replicas + pod anti-affinity
  - PVC for database
  - CronJob for database backups
- [ ] Integrate official Helm chart for the database (Bitnami)
- [ ] Build `infra-gitops` repo structure with Kustomize
- [ ] Build `app-gitops` repo structure with Kustomize
- [ ] Set up CI/CD pipeline:
  - Build + push Docker image on merge
  - Auto-deploy with health check
  - Auto-rollback on failure

### Phase 6 — Dex + oauth-proxy
- [ ] Deploy Dex as the OIDC identity provider
- [ ] Configure users or connect to GitHub/Google
- [ ] Put oauth-proxy in front of Dashboard, Grafana, Prometheus
- [ ] Test authentication end to end

### Phase 7 — Defense Scripts
- [ ] `deploy-app.sh` — full app deployment
- [ ] `break-deployment.sh` — deploys bad image, demos rollback
- [ ] Add failure endpoints to the app:
  - `/leak` — memory leak
  - `/cpu` — CPU loop
- [ ] Document all app setup steps

---

## Shared Responsibilities

| Task | Notes |
|------|-------|
| GitOps repo folder structure | Agree on layout before starting — both commit to these repos |
| Kubernetes labels convention | Must be consistent across all resources |
| Secrets management strategy | Pick one approach (native Secrets or Sealed Secrets) |
| Ingress hostnames | B sets up Ingress, A's tools also need routes — coordinate |
| Documentation | Each person documents what they built |
| Final defense walkthrough | Rehearse together at least twice |
| Bonus features | Tackle together after core is done |

---

## Dependency Order

Person A must complete the cluster bootstrap **before** Person B can deploy anything.
After that, both workstreams are fully independent.

```
Person A: [Terraform] → [kubeadm] → [Prometheus/Loki] → [OPA]
                  ↓
Person B:        [nginx-ingress] → [Dashboard] → [Helm chart] → [GitOps] → [Dex]
```

---

## Collaboration Tips

- **Use feature branches** — one branch per component, merge only when it deploys cleanly
- **Share a single `kubeconfig`** — both should be able to run `kubectl` at all times
- **Daily 10-min sync** — unblock dependencies early, especially around Ingress and auth
- **Test on the cluster early** — don't wait until everything is "done" to test