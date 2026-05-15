# `deploy.sh` — Automated GitOps Deploy

A single command from WSL builds, pushes, and rolls out a new version of the app.

```bash
# Use current $USER, auto-increment patch from the latest tag
./deploy.sh

# Deploy as a specific collaborator (selects their SSH key)
./deploy.sh cindy

# Explicit user + explicit tag
./deploy.sh cindy v0.2.0
```

---

## What it does

```
WSL (your laptop)
  │
  ├── Resolve kube-1 public IP via AWS CLI (tag lookup)
  │
  ├── (0) Query registry tags → resolve IMAGE_TAG
  │
  ├── (1) SSH → kube-1
  │        └── git pull → nerdctl build → nerdctl push → registry
  │
  ├── (2) SSH → each worker node (via kube-1 as jump host)
  │        └── ctr pull (pre-cache image)
  │
  └── (3) helm upgrade → cluster rolls out new image
```

Four stages plus a dynamic IP-resolution step, one command. Replaces the manual workflow from `PHASE_5_APP_GITOPS.md`.

---

## Configuration (top of the file)

| Variable | What it is | When to update |
|----------|------------|----------------|
| `KUBE1_NAME_TAG` | EC2 `Name` tag of the kube-1 instance | Only if you rename the instance |
| `AWS_REGION` | AWS region where kube-1 lives | Only if you move regions |
| `<USER>_SSH_KEY` | Path to each collaborator's PEM key (e.g. `CINDY_SSH_KEY`) | Once per collaborator |
| `REGISTRY` | Private registry address (internal IP:port) | Never (unless you move it) |
| `REPO_SSH` | GitHub SSH clone URL | Never |
| `REPO_DIR` | Where the repo lives on kube-1 | Never |
| `APP_KEY` / `DB_PASSWORD` / `DB_ROOT_PASSWORD` | Helm secrets | Move to `.env` if you don't want them in git |

`KUBE1_IP` is **not configured manually** — the script looks it up from AWS at runtime using the tag above, so it survives EC2 reboots automatically.

### Per-user SSH keys

Each collaborator declares their own PEM path with a `<UPPERCASE_USERNAME>_SSH_KEY` variable at the top of `deploy.sh`. Use **absolute paths** — `$HOME` breaks if anyone runs the script under `sudo`.

```bash
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"
# TEAMMATE_SSH_KEY="/home/teammate/projects/teammate-key-pair.pem"
```

The script picks the right one based on the first argument (or `$USER` if you don't pass one). The username is case-insensitive (`cindy`, `Cindy`, and `CINDY` all resolve to `CINDY_SSH_KEY`). If your username has no matching variable, the script fails fast and tells you exactly what line to add.

**macOS compatibility:** the lookup uses `tr` rather than bash 4's `${var^^}` so it works on macOS's built-in bash 3.2.

**Arguments:**

| Form | What it does |
|------|--------------|
| `./deploy.sh` | Uses `$USER` (your WSL username), auto-increments tag |
| `./deploy.sh cindy` | Deploys as `cindy` (uses `CINDY_SSH_KEY`), auto-increments tag |
| `./deploy.sh cindy v0.2.0` | Deploys as `cindy`, uses explicit tag (validated against the registry) |

Never reuse a tag (Kubernetes caches images by tag).

---

## Prerequisites — AWS CLI setup (one-time)

The script resolves kube-1's public IP via `aws ec2 describe-instances`, so the AWS CLI must be installed and configured on your WSL machine. Skip this section if `aws sts get-caller-identity` already works.

### 1. Install AWS CLI v2

```bash
sudo apt-get update && sudo apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
aws --version          # → aws-cli/2.x.x ...
```

### 2. Create an IAM access key

AWS Console → **IAM** → **Users** → your user → **Security credentials** → **Create access key** → choose *Command Line Interface (CLI)*. Copy both the Access Key ID and Secret Access Key before closing the page — the secret is shown only once.

**Minimal IAM permission needed:** `ec2:DescribeInstances`. A purpose-specific user with just that action is safer than reusing an admin key.

### 3. Configure the CLI

```bash
aws configure
```

| Prompt | Value |
|--------|-------|
| AWS Access Key ID | from step 2 |
| AWS Secret Access Key | from step 2 |
| Default region name | `eu-west-3a` |
| Default output format | `json` |

### 4. Verify

```bash
aws sts get-caller-identity
aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Name,Values=kube-1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text
```

The second command should print the kube-1 public IP. Once that works, `./deploy.sh` will resolve the IP automatically on every run.

---

## Stage 0 — Resolve image tag

Before building, the script queries the registry (`/v2/myapp/tags/list`) through kube-1 to get the list of existing tags.

| Input | Behavior |
|-------|----------|
| `./deploy.sh` (no arg) | Finds the highest `vX.Y.Z` tag, bumps the patch (`v0.1.2` → `v0.1.3`). Defaults to `v0.1.0` if the registry is empty. |
| `./deploy.sh v0.2.0` | Validates the tag isn't already in the registry. Fails with the list of existing tags if it is. |

Only `vX.Y.Z` semver tags are considered when sorting. Tags like `latest` or `dev` are ignored for auto-increment.

The registry is queried through kube-1 because it sits on a VPC-internal IP that WSL can't reach directly.

---

## Stage 1 — Build and push (on kube-1)

WSL opens an SSH session to kube-1 and runs a remote bash block that:

1. **Starts `buildkitd`** if not running (buildkit doesn't persist across reboots).
2. **Trusts GitHub's host key** with `ssh-keyscan` (needed on fresh EC2 instances).
3. **Clones or pulls the repo** — checks `$REPO_DIR/.git` to decide. If the directory exists but isn't a valid git repo (e.g. failed clone), it wipes it and re-clones.
4. **Builds the image** with `nerdctl build` from `sample-app/`.
5. **Pushes to the private registry** with `--insecure-registry` (registry is plain HTTP).
6. **Verifies** by hitting `/v2/myapp/tags/list`.

> Why build on kube-1? `nerdctl` and `buildkitd` are installed there, and it sits on the same VPC as the registry. WSL can't push to the registry directly.

---

## Stage 2 — Pre-pull on all worker nodes

The cluster's containerd doesn't reliably honor the `hosts.toml` insecure-registry config for kubelet-initiated pulls — kubelet keeps trying HTTPS and hitting `http: server gave HTTP response to HTTPS client`.

**Workaround:** before triggering the rollout, manually pull the image on every node so the kubelet finds it cached locally and skips the network pull.

Mechanics:

1. WSL runs `kubectl get nodes -o jsonpath='...InternalIP...'` to get every node's private IP.
2. For each node, WSL opens an SSH session **using kube-1 as a jump host** (`ProxyCommand`). This is needed because worker nodes only have private IPs that aren't reachable from outside the VPC.
3. The remote command is `sudo ctr -n k8s.io images pull --plain-http ...` — `ctr` bypasses the CRI and pulls directly into the kubelet's containerd namespace.

```bash
WSL ──(PEM key)──→ kube-1 (jump) ──→ worker (private IP)
```

WSL holds the key for both hops — kube-1 never needs to know about the worker SSH keys.

`|| true` after each pull ensures one failing node doesn't abort the whole deploy.

---

## Stage 3 — Helm upgrade

A standard `helm upgrade myapp ./infra-gitops/charts/myapp` with:

- Image repository and tag set from the script variables
- Secrets injected via `--set`
- `mysql.enabled=false` because the MySQL Deployment is managed by the chart's `mysql.yaml`, not the Bitnami subchart
- `--wait --timeout 5m` so the command blocks until the rollout completes (or fails)

If `--wait` times out, Helm marks the release as failed. You can roll back with `helm rollback myapp -n myapp`.

---

## Final verification

```bash
kubectl rollout status deployment/myapp-myapp -n myapp
kubectl get pods -n myapp -o wide
```

If the rollout finished successfully, the new version is live.

---

## After a kube-1 reboot

The EC2 public IP changes, but **`deploy.sh` no longer needs a manual update** — it resolves the fresh IP from AWS at the start of every run.

You still need to refresh your local kubeconfig so `kubectl` can reach the API server on the new IP:

```bash
NEW_IP=$(aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Name,Values=kube-1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
sed -i "s|https://.*:6443|https://$NEW_IP:6443|" ~/.kube/config
kubectl get nodes
```

`buildkitd` is auto-started by the script. The registry container restarts automatically.

---

## Rollback

If something goes wrong:

```bash
# Helm-managed rollback (preferred)
helm rollback myapp -n myapp

# Or roll back to a specific revision
helm history myapp -n myapp
helm rollback myapp 12 -n myapp

# Bypass Helm entirely
kubectl rollout undo deployment/myapp-myapp -n myapp
```

---

## Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `tag '...' already exists in the registry` | You passed a tag that's already in the registry | Use a higher tag, or omit the argument to auto-increment |
| `No SSH key configured for user '<name>'` | Your username has no `<UPPERCASE>_SSH_KEY` variable | Add the line the script suggests at the top of `deploy.sh` |
| `SSH key not found at <path>` | Variable is set but the file doesn't exist | Fix the path, or move/rename the `.pem` to match |
| `Could not resolve a running instance tagged Name=kube-1` | AWS CLI not configured, wrong region, or kube-1 stopped | Run `aws sts get-caller-identity` to check creds; verify `AWS_REGION`; confirm the instance is running |
| `aws: command not found` | AWS CLI v2 not installed on WSL | See [Prerequisites — AWS CLI setup](#prerequisites--aws-cli-setup-one-time) |
| `Permission denied (publickey)` on stage 1 | PEM key path wrong or permissions too open | `chmod 600` the key; update `SSH_KEY` |
| `Host key verification failed` cloning the repo | Fresh kube-1, no GitHub host key | Already handled by `ssh-keyscan` in the script |
| `destination path '~/KubeQuest' already exists` | Previous clone failed mid-way | Already handled — script wipes incomplete clones |
| `Chart.yaml file is missing` | File is named `Charts.yaml` (with `s`) | Rename to `Chart.yaml` |
| `ImagePullBackOff` after deploy | Pre-pull didn't reach that node | Check `kubectl describe pod`; manually `ctr pull` on the failing node |
| `context deadline exceeded` on helm upgrade | Pods aren't becoming ready in 5min | Drop `--wait` and inspect with `kubectl describe pod` |
| `bad character U+003E '>'` in template | Helm template file got truncated (line cut off) | Open the template file and complete the truncated line |

---

## Image tag convention

| Release type | Example |
|--------------|---------|
| Initial | `v0.1.0` |
| Bug fix | `v0.1.1` |
| Feature | `v0.2.0` |

Never reuse a tag. Kubernetes caches images by tag — a reused tag means stale images on some nodes with no error.