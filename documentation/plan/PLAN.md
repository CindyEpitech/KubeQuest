# KubeQuest — Plan

The 12 bonus items grouped into 4 ordered phases. Each phase has clear pass criteria so you know when to move on.

| Phase | Theme | Effort | Why this order |
|-------|-------|--------|----------------|
| **A** | Verify foundations | ½–1 day | Prove existing claims (persistence, backup) work and add automatic rollback. Finding a broken foundation 2 days before demo is fatal. |
| **B** | Demo polish | 2–3 days | High visual impact, low effort. This is what the jury sees. |
| **C** | Security baseline | 2–3 days | Scores points on the security rubric and makes the demo credible. |
| **D** | Heavy lifts | 3–5 days | Restructures how things work. Only safe to start once A–C are solid. |

---

## Dependency rules between phases

- **A.3 (automatic rollback) before D.1 (CI)** — CI failing a bad deploy is great, but runtime failures must also roll back without CI's help.
- **C.1 (secrets) before C.2 (auth)** — Dex stores its own client secret, oauth2-proxy stores a cookie secret. Clean secret storage first.
- **B.1 (load test) needs B.3 (alerts)** to demo well — the memory alert should *not* fire during normal HPA scaling, but *should* fire when you overwhelm the cluster on purpose.
- **D.2 (ArgoCD) last** — once ArgoCD owns deploys, `deploy.sh` becomes obsolete. Don't migrate until the manual path is rock-solid.

---

# Phase A — Verify foundations

## A.1 — Data persistence *(20 min)*

The MySQL Deployment mounts the `mysql-data` PVC at `/var/lib/mysql`. Prove persistence by writing data, killing the pod, and verifying the data survives.

### Step 1 — Confirm the PVC is bound

```bash
kubectl get pvc -n myapp mysql-data
kubectl get pv $(kubectl get pvc -n myapp mysql-data -o jsonpath='{.spec.volumeName}')
```

If `STATUS` is `Pending`, fix the storage class before continuing.

### Step 2 — Write a sentinel row

```bash
MYSQL_POD=$(kubectl get pod -n myapp -l app=mysql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n myapp -it $MYSQL_POD -- mysql -uroot -p"$DB_ROOT_PASSWORD" app_database -e \
  "CREATE TABLE IF NOT EXISTS persistence_test (id INT, note VARCHAR(50));
   INSERT INTO persistence_test VALUES (1, 'survived');
   SELECT * FROM persistence_test;"
```

### Step 3 — Kill the pod, wait for the new one

```bash
kubectl delete pod -n myapp $MYSQL_POD
kubectl rollout status deployment/mysql -n myapp
```

### Step 4 — Read the row from the new pod

```bash
MYSQL_POD=$(kubectl get pod -n myapp -l app=mysql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n myapp -it $MYSQL_POD -- mysql -uroot -p"$DB_ROOT_PASSWORD" app_database -e \
  "SELECT * FROM persistence_test;"
```

**Pass criterion:** the `survived` row is still there.
**Cleanup:** `DROP TABLE persistence_test;`.

> If the row is gone, the PVC isn't backing `/var/lib/mysql` correctly — most likely a `local-path-provisioner` issue or an `emptyDir` somewhere by mistake.

---

## A.2 — Verify DB backup *(45 min)*

Backup CronJob is `myapp-myapp-db-backup`, runs daily at `02:00`, dumps into PVC `myapp-backup-pvc`, keeps last 7.

### Step 1 — Confirm CronJob and PVC

```bash
kubectl get cronjob -n myapp
kubectl get pvc -n myapp myapp-backup-pvc
```

### Step 2 — Trigger a manual run

```bash
kubectl create job -n myapp manual-backup-$(date +%s) \
  --from=cronjob/myapp-myapp-db-backup
kubectl get jobs -n myapp -w
kubectl logs -n myapp -l job-name=manual-backup-<id> --tail=20
# Expect: "Backup done."
```

### Step 3 — Inspect the backup files

Spin a one-shot debug pod that mounts the backup PVC:

```bash
kubectl run -n myapp backup-inspector --rm -it --restart=Never \
  --image=busybox \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "backup-inspector",
      "image": "busybox",
      "stdin": true,
      "tty": true,
      "command": ["sh"],
      "volumeMounts": [{"name":"b","mountPath":"/backup"}]
    }],
    "volumes": [{"name":"b","persistentVolumeClaim":{"claimName":"myapp-backup-pvc"}}]
  }
}' -- sh

# Inside the pod:
ls -lh /backup
cat /backup/backup-*.sql | head -20    # should look like SQL
exit
```

### Step 4 — Prove the backup is *restorable*

A backup you can't restore is not a backup. Restore the latest dump into a scratch MySQL pod and `SELECT COUNT(*)` on a few tables to confirm row counts match production.

**Pass criterion:** the scratch DB has the same tables and row counts as production.

> If you skip the full restore for time, at minimum confirm the `.sql` file opens with valid `CREATE TABLE` / `INSERT` statements and is non-empty.

---

## A.3 — Auto-rollback on unhealthy deploy *(10 min)*

One-line change to [deploy.sh](../../deploy.sh). Helm's `--rollback-on-failure` means "if the deploy fails or times out, roll back automatically".

### Step 1 — Add `--rollback-on-failure` (and `--install` for idempotency)

In `deploy.sh`, find the `helm upgrade myapp` block and add the flags:

```bash
helm upgrade myapp "$SCRIPT_DIR/infra-gitops/charts/myapp" \
  --namespace myapp \
  --install \
  --rollback-on-failure \
  --set image.repository="$REGISTRY/myapp" \
  --set image.tag="$IMAGE_TAG" \
  ...
  --wait \
  --timeout 5m
```

### Step 2 — Prove it by forcing a failure

```bash
./deploy.sh cindy v99.99.99-broken
```

The pod goes `ImagePullBackOff`, `--wait` times out, Helm auto-rolls-back.

Verify:

```bash
helm history myapp -n myapp
kubectl get deploy -n myapp -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'
```

**Pass criterion:** the deploy failed, but the cluster is still running the previous working version.

`--rollback-on-failure` covers two bonus items at once: **auto rollback** and **cancel deployment when unhealthy** (Helm waits for readiness, fails the deploy if probes don't go green within `--timeout`, then rolls back).

---

## Phase A checklist

```
[x] A.1.1  PVC mysql-data is Bound
[x] A.1.4  Sentinel row survives pod deletion
[x] A.2.2  Manual CronJob run completes
[x] A.2.3  Backup .sql file exists on the PVC
[x] A.2.4  Backup restores cleanly into a scratch DB
[x] A.3.1  --rollback-on-failure + --install added to deploy.sh
[x] A.3.2  Forced bad deploy auto-rolls-back
```

---

# Phase B — Demo polish

## B.1 — Live load test (HPA scaling) *(½ day)*

Write `load-test.sh` (referenced in [PHASE_7_DEFENSE.md](PHASE_7_DEFENSE.md)). Use `hey` or `wrk` to hammer a CPU-heavy endpoint (`/cpu`) and watch HPA scale 2 → 6 replicas in real time.

Key commands during demo:
- `kubectl get hpa -n myapp -w` (left terminal)
- `kubectl get pods -n myapp -w` (middle terminal)
- `./load-test.sh` (right terminal)

**Pass criterion:** replicas scale up under load, scale back down after load stops, no 5xx errors during scaling.

## B.2 — Two-page Grafana dashboard *(½ day)*

Build two dashboards (one app-focused, one infra-focused):

**App dashboard** — request rate, p95 latency, replica count, pod restarts, HPA target vs current.

**Infra dashboard** — CPU/memory per node, disk usage on monitoring node, network in/out, top noisy pods.

Save both to JSON and commit them to the repo so they survive a Grafana redeploy.

## B.3 — Memory alert in Grafana Alerting *(½ day)*

Grafana UI → Alerting → New alert rule.

Suggested rule:
- **Query:** `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100`
- **Condition:** `< 20` for `5m`
- **Notification:** Slack / email / display in dashboard
- **Title:** "Node memory low: {{ $labels.instance }}"

**Pass criterion:** alert fires when you intentionally exhaust memory (e.g. `stress-ng --vm 2 --vm-bytes 2G`), recovers when load stops.

## B.4 — Polish one-click deploy *(½ day)*

[deploy.sh](../../deploy.sh) is already 90% there. Final pass:
- Color-coded status output (green OK, red FAIL)
- Timestamps on each stage
- Pre-flight checks (kubectl context, AWS creds, registry reachability) before doing any work
- Final summary block: deployed tag, replicas, URL

---

# Phase C — Security baseline

## C.1 — Proper secret storage *(1 day)*

Today `APP_KEY`, `DB_PASSWORD`, `DB_ROOT_PASSWORD` are passed via `--set` from `deploy.sh` and live in git. Replace with one of:

| Option | Effort | Trade-off |
|--------|--------|-----------|
| **K8s Secret + `--set-file`** | Low | Secrets still exist in plaintext on the WSL machine; not in git |
| **sealed-secrets** | Medium | Encrypted secrets *can* live in git, decrypted server-side by the controller |
| **external-secrets-operator** | High | Secrets live in AWS Secrets Manager or Vault; cluster pulls at runtime |

Recommended: **sealed-secrets** — best balance for a school project, demonstrates secret hygiene.

**Pass criterion:** `git grep -i "base64:DJYTvaRkEZ"` returns nothing in the repo, but the app still starts after a fresh deploy.

## C.2 — Cluster authentication (Dex + oauth2-proxy) *(1–2 days)*

Already specced in [PHASE_6_SECURITY.md](PHASE_6_SECURITY.md). Puts an OIDC login screen in front of Dashboard, Grafana, and Prometheus.

Steps:
1. Install Dex (Helm chart)
2. Configure a local user `admin@kubequest.local` with a strong password
3. Install oauth2-proxy as a sidecar/separate Deployment
4. Update Grafana/Dashboard/Prometheus Ingresses with `nginx.ingress.kubernetes.io/auth-url` and `auth-signin` annotations
5. Test: open `grafana.kubequest.local` in incognito → expect login screen → after login, normal Grafana

**Pass criterion:** all three protected URLs prompt for login; same-session SSO works across them.

---

# Phase D — Heavy lifts

## D.1 — CI tests blocking deploy *(2–3 days)*

GitHub Actions workflow that runs on every PR:
1. Composer install
2. PHPUnit tests
3. (Optional) PHPStan / linter
4. Build a temporary Docker image to confirm the Dockerfile is valid

Branch protection: require the workflow to be green before merge.

**Optional deeper integration:** make `deploy.sh` refuse to run if `git rev-parse HEAD` doesn't match a commit that has a green CI run (query via `gh run list`).

**Pass criterion:** a PR with deliberately broken tests cannot be merged.

## D.2 — ArgoCD (GitOps automation) *(2–3 days)*

Already specced in [PHASE_8_BONUSES.md](PHASE_8_BONUSES.md#bonus-1--argocd-gitops-automation). Replaces `deploy.sh` with pull-based GitOps.

Migration plan:
1. Install ArgoCD (manifests from PHASE_8_BONUSES.md)
2. Expose via Ingress at `argocd.kubequest.local`
3. Create two Applications — one for `infra-gitops/`, one for the chart in `charts/myapp/`
4. Enable `automated.selfHeal=true` and `automated.prune=true`
5. Test: push a change to git → ArgoCD picks it up → cluster syncs automatically
6. Keep `deploy.sh` around for fallback / emergencies

**Pass criterion:** a `git push` to main triggers a sync visible in the ArgoCD UI within 3 minutes, no manual command needed.

---

# Full bonus checklist

```
Phase A
[x] Persistance verified
[x] DB backup verified end-to-end (including restore)
[x] --rollback-on-failure / --install added to deploy.sh, rollback proven

Phase B
[ ] Live load test demonstrates HPA scaling
[ ] Two-page Grafana dashboard committed to repo
[ ] Memory alert configured and tested in Grafana Alerting
[ ] deploy.sh polished (colors, timestamps, pre-flight)

Phase C
[ ] Secrets removed from git; deploy still works
[ ] Dex + oauth2-proxy protecting Grafana / Dashboard / Prometheus

Phase D
[ ] CI gates merges to main
[ ] ArgoCD owns deploys; git push = cluster update
```

When all boxes are ticked, you've covered every item on the bonus list plus the core demo requirements.
