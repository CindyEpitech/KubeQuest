# ArgoCD — Operational Notes (Phase D.2)

Practical gotchas and reminders for running the KubeQuest ArgoCD setup.
For install steps and the full design, see
[`infra-gitops/argocd/README.md`](../infra-gitops/argocd/README.md).

```
- URL: http://argocd.kubequest.local (needs 10.98.36.134  argocd.kubequest.local in your /etc/hosts)
- Username: admin
- Password: X6qPbOkbaXDIkdAV
```
---

## ✅ Branch tracking reconciled (2026-05-29)

There was previously a divergence: the live Applications were installed
**overridden to track `develop`** for sync testing, while the committed manifests
in `infra-gitops/argocd/applications/` tracked **`main`**. This was needed because
`main` was behind `develop` and missing `values-production.yaml` and the
`secret.create` toggle — syncing `myapp` against `main` would have failed and
clobbered the live secrets.

**This is now resolved.** `develop` was fast-forward merged into `main` and the live
apps were re-pointed to the committed manifests:

```bash
git checkout main && git merge --ff-only develop && git push origin main
kubectl apply -f infra-gitops/argocd/applications/
```

Current expected state — committed YAML and live cluster now match:

| App | Tracks | Namespace |
|-----|--------|-----------|
| `infra`     | `main`    | `default`   |
| `myapp`     | `main`    | `myapp`     |
| `myapp-dev` | `develop` | `myapp-dev` |

The pre-created `myapp-secret` / `myapp-db-secret` survived the re-point (annotation
tracking did its job). `myapp-dev` tracking `develop` is **by design** (it's the dev
environment), not drift.

---

## ⚠️ ArgoCD must use annotation-based resource tracking

The `myapp` Helm chart labels its objects with `app.kubernetes.io/instance: myapp`,
which is ArgoCD's **default tracking label**. With default (label) tracking, ArgoCD
adopted the pre-created `myapp-secret` / `myapp-db-secret` (which the chart skips
under `secret.create=false`) and **pruned them** — new pods then failed with
`secret "myapp-secret" not found`.

**Fix (committed):** `application.resourceTrackingMethod: annotation` in
`argocd-cm` (see `infra-gitops/argocd/cm.yaml`). Keep this set.

**If the secrets ever get pruned again,** recreate them with the values from
`scripts/deploy.sh`:

```bash
kubectl -n myapp create secret generic myapp-secret \
  --from-literal=app-key="$APP_KEY"
kubectl -n myapp create secret generic myapp-db-secret \
  --from-literal=mysql-password="$DB_PASSWORD" \
  --from-literal=mysql-root-password="$DB_ROOT_PASSWORD"
```

---

## HPA vs selfHeal

The `myapp` Application has `ignoreDifferences` on Deployment `/spec/replicas` so
ArgoCD's `selfHeal` does not fight the HorizontalPodAutoscaler. Leave it in place.

---

## Access

- **URL:** http://argocd.kubequest.local (add the ingress IP to `/etc/hosts`,
  same as the other `*.kubequest.local` hosts)
- **User:** `admin`
- **Initial password:**
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```

---

## Verified sync tests (2026-05-29)

- **selfHeal:** manually drifted HPA `maxReplicas` → ArgoCD reverted to the git value.
- **git-push → auto-sync:** pushed a values change → ArgoCD applied it live in ~114s
  (under the 3-minute pass criterion), no manual command.
