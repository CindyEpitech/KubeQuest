# KubeQuest — Phase 5: Application GitOps
> Helm | nerdctl | Manual GitOps | Auto-rollback

---

## Overview

Deploy and update the Laravel application declaratively using the Helm chart from Phase 4.
Every update follows the same GitOps loop: build a new image on kube-1, push it to the private registry, and upgrade the Helm release from WSL.

---

## Actual Workflow

```
WSL (local machine)
  └── scp source code ──→ kube-1
                              └── nerdctl build + push ──→ registry (10.0.9.227:5000)
WSL
  └── helm upgrade ──→ cluster pulls new image from registry
```

---

## Prerequisites

- Phase 4 complete — Helm release `myapp` running in namespace `myapp`
- `kubectl` and `helm` configured on WSL (see Phase 2 — WSL)
- nerdctl + buildkitd installed on kube-1 (see Phase 4 — Registry)

---

## Step 1 — Copy Updated Code to kube-1

From **WSL**:

```bash
scp -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem \
  -r /home/cindy/projects/KubeQuest/sample-app-master \
  ec2-user@35.181.55.161:~/
```

---

## Step 2 — Build and Push New Image on kube-1

SSH into kube-1:

```bash
ssh -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem ec2-user@35.181.55.161
```

Build and push:

```bash
# Make sure buildkitd is running (required after every reboot)
sudo buildkitd &
sleep 2

cd ~/sample-app-master

# Increment the tag for every release
export IMAGE_TAG=v0.1.1

sudo nerdctl build -t 10.0.9.227:5000/myapp:$IMAGE_TAG .
sudo nerdctl push --insecure-registry 10.0.9.227:5000/myapp:$IMAGE_TAG

# Verify the image is in the registry
curl http://10.0.9.227:5000/v2/myapp/tags/list
```

---

## Step 3 — Upgrade the Helm Release (from WSL)

```bash
cd /home/cindy/projects/KubeQuest/infra-gitops

helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.repository=10.0.9.227:5000/myapp \
  --set image.tag=v0.1.1 \
  --set secret.appKey="$APP_KEY" \
  --set secret.dbPassword="$DB_PASSWORD" \
  --set secret.dbRootPassword="$DB_ROOT_PASSWORD" \
  --set mysql.enabled=false \
  --wait \
  --timeout 5m
```

> Always pass `--set mysql.enabled=false` on upgrade — the MySQL Deployment is managed by `mysql.yaml`, not the Bitnami subchart.

---

## Step 4 — Run Migrations (if schema changed)

Only required when the database schema has changed:

```bash
# Get a running app pod name
kubectl get pods -n myapp

kubectl exec -n myapp <pod-name> -- php /var/www/html/artisan migrate --force
```

---

## Step 5 — Verify

```bash
# Watch the rollout
kubectl rollout status deployment/myapp-myapp -n myapp

# Check pods
kubectl get pods -n myapp -o wide

# Test the app
curl http://app.kubequest.local
```

---

## Rollback

### Automatic rollback on upgrade failure

`--wait` causes `helm upgrade` to wait for the rollout to succeed. If pods fail to become ready within the timeout, Helm marks the release as failed. Roll back immediately:

```bash
helm rollback myapp -n myapp
```

### Manual rollback via Helm history

```bash
# View release history
helm history myapp -n myapp

# Roll back to a previous revision
helm rollback myapp 2 -n myapp
```

### Manual rollback via kubectl

```bash
# View deployment history
kubectl rollout history deployment/myapp-myapp -n myapp

# Roll back to previous version
kubectl rollout undo deployment/myapp-myapp -n myapp

# Roll back to a specific revision
kubectl rollout undo deployment/myapp-myapp -n myapp --to-revision=2

# Confirm rollback completed
kubectl rollout status deployment/myapp-myapp -n myapp
```

---

## Image Tag Convention

Increment the tag on every release — never reuse a tag:

| Release | Tag |
|---------|-----|
| Initial | `v0.1.0` |
| Bug fix | `v0.1.1` |
| Feature | `v0.2.0` |

> Kubernetes caches images by tag. Reusing a tag (e.g. `latest`) means nodes may run a stale image without any error.

---

## After a Reboot of kube-1

buildkitd does not persist. Before building any image:

```bash
sudo buildkitd &
sleep 2
sudo buildctl debug workers
```

The registry container restarts automatically (`--restart always`).

The public IP of kube-1 changes — update kubeconfig from WSL:

```bash
NEW_IP=<new-public-ip>
sed -i "s|https://.*:6443|https://$NEW_IP:6443|" ~/.kube/config
kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true
kubectl get nodes
```

---

## Monitor Deployments

```bash
# Watch rollout in real time
kubectl rollout status deployment/myapp-myapp -n myapp

# Watch pods during deployment
kubectl get pods -n myapp -w

# Check recent events
kubectl get events -n myapp --sort-by='.lastTimestamp'

# App logs
kubectl logs -n myapp deployment/myapp-myapp --tail=50
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `ImagePullBackOff` | Pre-pull on the target node: `sudo ctr -n k8s.io images pull --plain-http 10.0.9.227:5000/myapp:<tag>` |
| `--wait` timeout | Remove `--wait` and check pod logs manually: `kubectl logs -n myapp <pod>` |
| Pod stuck `Init:0/1` | Check MySQL service exists: `kubectl get svc myapp-mysql -n myapp` |
| `cannot re-use a name that is still in use` | Release already exists — use `helm upgrade`, not `helm install` |
| Helm rollback fails | Check history: `helm history myapp -n myapp`; use `kubectl rollout undo` as fallback |
| 500 after upgrade | New migrations needed — run `artisan migrate --force` |
| buildkitd not found | Run `sudo buildkitd &` on kube-1 |

---

## Next Step

Once automated deploys and rollbacks are working, proceed to:
**[Phase 6 — Security Layer](./PHASE_6_SECURITY.md)**
