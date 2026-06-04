# `deploy.sh` — GitOps Deploy

`deploy.sh` does **not** touch the cluster directly. It builds (dev) or promotes
(prod) an image, bumps the image tag in the right Helm values file, and **pushes
to Git**. ArgoCD watches the repo and rolls the change out — **the git push is the
deploy.** The script then waits until ArgoCD reports the new tag Synced + Healthy.

```bash
# Build the current develop branch, auto-increment the tag, ship to dev
./deploy.sh dev

# Build develop with an explicit tag
./deploy.sh dev cindy v0.2.0

# Promote the tag dev is currently running into production
./deploy.sh prod

# Promote a specific (already-built) tag into production
./deploy.sh prod cindy v0.1.9
```

> **Why this changed:** ArgoCD now owns rollout. The old script ran `helm upgrade`
> directly, which fought ArgoCD's `selfHeal` (it would revert the imperative
> change back to whatever Git said). The deploy is now "build the artifact, then
> commit the tag." See [`concept/ARGOCD.md`](concept/ARGOCD.md) and
> [`ARGOCD_NOTES.md`](ARGOCD_NOTES.md).

---

## dev vs prod

| | `./deploy.sh dev` | `./deploy.sh prod` |
|---|---|---|
| Source branch | `develop` | `main` |
| Builds an image? | **Yes** (on kube-1) | **No** — promotes an existing one |
| Tag chosen | new auto-increment, or explicit (must NOT exist yet) | the tag dev runs, or explicit (must already exist) |
| Values file bumped | `values-dev.yaml` | `values-production.yaml` |
| Pushed to | `develop` | `main` |
| ArgoCD app / namespace | `myapp-dev` / `myapp-dev` | `myapp` / `myapp` |
| URL | http://app-dev.kubequest.local | http://app.kubequest.local |

The normal release path: `./deploy.sh dev` → eyeball the dev URL → `./deploy.sh prod`.
prod **reuses the exact image dev tested** (it never rebuilds), which is the whole
point of promotion.

---

## Branch automation (GitHub Actions)

Two workflows in [`.github/workflows/`](../.github/workflows/) keep the
`develop` → `main` → prod flow tidy so you rarely touch branches by hand:

| Workflow | Trigger | What it does |
|---|---|---|
| `promote.yml` | push to `main` changing `values-dev.yaml` | Opens a PR copying the dev image tag into `values-production.yaml`. Merging it rolls the tag out to prod via ArgoCD (no rebuild). |
| `sync-develop.yml` | any push to `main` | Fast-forwards `develop` up to `main` so the two stay in lockstep and the next `develop → main` PR shows a clean diff. |

`sync-develop.yml` uses `git merge --ff-only` as a guard: if someone has pushed
**directly** to `develop` since the last merge to `main`, it can't fast-forward, so
it **fails the run** (with reconcile instructions) instead of creating a tangle —
in that case run `git checkout develop && git merge origin/main && git push` once.

> So after a PR merges to `main`, `develop` catches up automatically — no manual
> `git merge origin/main`. (If `develop` is ever a protected branch, the Action's
> token push may need to be allowed.)

---

## What it does

```
WSL (your laptop)
  │
  ├── Resolve kube-1 public IP via AWS CLI, point kubectl at it
  │
  ├── Clone the repo into a scratch dir (never touches your working tree)
  │
  ├── Resolve IMAGE_TAG
  │     dev  → next free vX.Y.Z from the registry (or your explicit tag)
  │     prod → the tag in develop's values-dev.yaml (or your explicit tag),
  │            verified to exist in the registry
  │
  ├── dev only: SSH → kube-1 → nerdctl build + push → registry
  │             SSH → each node (via kube-1) → ctr pull  (pre-cache)
  │
  ├── sed the `tag:` in the values file → git commit → git push  ← the deploy
  │
  └── Nudge ArgoCD refresh, poll until Synced + Healthy on the new tag
```

All git work happens in a throwaway clone (`mktemp -d`, auto-removed on exit), so
your working tree, current branch, and any uncommitted files are never disturbed.

---

## Configuration (top of the file)

| Variable | What it is | When to update |
|----------|------------|----------------|
| `KUBE1_NAME_TAG` | EC2 `Name` tag of the kube-1 instance | Only if you rename the instance |
| `AWS_REGION` | AWS region where kube-1 lives | Only if you move regions |
| `<USER>_SSH_KEY` | Path to each collaborator's PEM key (e.g. `CINDY_SSH_KEY`) | Once per collaborator |
| `REGISTRY` | Private registry address (internal IP:port) | Never (unless you move it) |
| `REPO_SSH` | GitHub SSH clone URL | Never |
| `REPO_DIR` | Where the repo lives on kube-1 (build checkout) | Never |
| `SYNC_TIMEOUT` | Seconds to wait for ArgoCD to converge before giving up | If rollouts are slow |

`KUBE1_IP` is **not configured manually** — the script looks it up from AWS at
runtime, so it survives EC2 reboots automatically.

> **No more app secrets.** The chart sets `secret.create: false` and the
> `myapp` / `myapp-dev` secrets are pre-created in the cluster, so the script no
> longer reads or injects `APP_KEY` / `DB_PASSWORD` / `DB_ROOT_PASSWORD`. If those
> secrets ever get lost, recreate them from the commands in `ARGOCD_NOTES.md`.

### Per-user SSH keys (EC2, not GitHub)

Each collaborator declares their own PEM path with a `<UPPERCASE_USERNAME>_SSH_KEY`
variable at the top of `deploy.sh`. Use **absolute paths** — `$HOME` breaks under `sudo`.

```bash
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"
# TEAMMATE_SSH_KEY="/home/teammate/projects/teammate-key-pair.pem"
```

The script picks the right one from the **second** argument (or `$USER` if omitted).
Case-insensitive (`cindy` / `Cindy` / `CINDY` all resolve to `CINDY_SSH_KEY`). The
lookup uses `tr` (not bash 4's `${var^^}`) so it works on macOS's bash 3.2.

> These keys are for SSH to the **EC2 nodes**. Cloning/pushing the repo uses your
> normal **GitHub** SSH key — make sure `git push` already works for you.

**Arguments:**

| Form | What it does |
|------|--------------|
| `./deploy.sh dev` | Build develop as `$USER`, auto-increment the tag |
| `./deploy.sh dev cindy` | Build develop as `cindy` (uses `CINDY_SSH_KEY`) |
| `./deploy.sh dev cindy v0.2.0` | Build develop with an explicit, not-yet-existing tag |
| `./deploy.sh prod` | Promote dev's current tag to prod |
| `./deploy.sh prod cindy v0.1.9` | Promote a specific existing tag to prod |

---

## Prerequisites — AWS CLI setup (one-time)

The script resolves kube-1's public IP via `aws ec2 describe-instances`, so the AWS
CLI must be installed and configured on your WSL machine. Skip this if
`aws sts get-caller-identity` already works.

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

AWS Console → **IAM** → **Users** → your user → **Security credentials** →
**Create access key** → *Command Line Interface (CLI)*. Copy both keys before
closing — the secret is shown only once.

**Minimal IAM permission needed:** `ec2:DescribeInstances`.

### 3. Configure the CLI

```bash
aws configure
```

| Prompt | Value |
|--------|-------|
| AWS Access Key ID | from step 2 |
| AWS Secret Access Key | from step 2 |
| Default region name | `eu-west-3` |
| Default output format | `json` |

### 4. Verify

```bash
aws sts get-caller-identity
aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Name,Values=kube-1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text
```

The second command should print the kube-1 public IP. Once that works, `deploy.sh`
resolves the IP automatically on every run.

---

## Stage: resolve the image tag

The script queries the registry (`/v2/myapp/tags/list`) through kube-1 (the registry
sits on a VPC-internal IP WSL can't reach directly). Only `vX.Y.Z` semver tags count.

| Env / input | Behavior |
|-------------|----------|
| `dev` (no tag) | Highest `vX.Y.Z` + patch bump (`v0.1.8` → `v0.1.9`); `v0.1.0` if empty |
| `dev v0.2.0` | Fails if the tag **already exists** (you're about to build it) |
| `prod` (no tag) | Reads the tag from `origin/develop:values-dev.yaml` |
| `prod v0.1.9` | Uses that tag; fails if it is **not** in the registry yet |

---

## Stage: build & push (dev only, on kube-1)

WSL opens an SSH session to kube-1 and runs a remote bash block that:

1. **Starts `buildkitd`** if not running (doesn't persist across reboots).
2. **Trusts GitHub's host key** with `ssh-keyscan`.
3. **Clones or hard-resets** the repo to `origin/develop` (so it builds exactly
   what's pushed — commit & push your app code first).
4. **Builds** with `nerdctl build` from `sample-app/`.
5. **Pushes** to the private registry with `--insecure-registry` (plain HTTP).

> Why build on kube-1? `nerdctl`/`buildkitd` live there and it's on the same VPC as
> the registry. WSL can't push to the registry directly. prod skips this entirely.

---

## Stage: pre-pull on all worker nodes (dev only)

Kubelet doesn't reliably honor the insecure-registry config for its own pulls, so
the script pre-pulls the image on every node first. It SSHes to each node **using
kube-1 as a jump host** (`ProxyCommand`, since workers only have private IPs) and
runs `sudo ctr -n k8s.io images pull --plain-http ...`.

```bash
WSL ──(PEM key)──→ kube-1 (jump) ──→ worker (private IP)
```

`|| true` after each pull means one unreachable node doesn't abort the deploy.

---

## Stage: commit the tag bump (the actual deploy)

In the scratch clone, the script `sed`s the `tag:` line of the values file to the
new tag, commits `chore(deploy): <env> image tag -> <tag>`, and pushes the branch.
If the file is already at that tag it stops (nothing to deploy).

That push is the only thing that changes the cluster — from here ArgoCD takes over.

---

## Stage: wait for ArgoCD

The script annotates the Application with `argocd.argoproj.io/refresh=normal` to
trigger an immediate sync (instead of waiting up to ~3 min for the next poll), then
loops until **all three** are true (or `SYNC_TIMEOUT` is hit):

- Application `status.sync.status == Synced`
- Application `status.health.status == Healthy`
- the live Deployment's image actually contains the new tag

You can watch the same thing by hand:

```bash
kubectl -n argocd get app myapp-dev          # or myapp
kubectl -n myapp-dev get deploy myapp-myapp -o jsonpath='{..image}'; echo
```

---

## Rollback (GitOps)

Rollback is also a Git operation now — **don't** use `helm rollback` or
`kubectl rollout undo`, ArgoCD's `selfHeal` would just revert you. Instead, point
the tag back to a known-good value and push:

```bash
# Quickest: re-promote / re-deploy an older tag
./deploy.sh dev  cindy v0.1.7      # dev
./deploy.sh prod cindy v0.1.7      # prod

# Or revert the bump commit
git revert <deploy-commit> && git push     # ArgoCD syncs back
```

ArgoCD also keeps history — you can roll back from the ArgoCD UI (App → History
and rollback) or `argocd app rollback`.

---

## After a kube-1 reboot

The EC2 public IP changes, but `deploy.sh` resolves the fresh IP from AWS on every
run. You still need to refresh your local kubeconfig so `kubectl` reaches the API:

```bash
NEW_IP=$(aws ec2 describe-instances --region eu-west-3 \
  --filters "Name=tag:Name,Values=kube-1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
sed -i "s|https://.*:6443|https://$NEW_IP:6443|" ~/.kube/config
kubectl get nodes
```

`buildkitd` is auto-started by the script; the registry container restarts automatically.

---

## Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `First argument must be 'dev' or 'prod'` | Missing/!valid env arg | Run `./deploy.sh dev` or `./deploy.sh prod` |
| `Tag '...' already exists in the registry` (dev) | You passed a tag that's already built | Use a higher tag, or omit it to auto-increment |
| `Tag '...' is not in the registry` (prod) | Promoting a tag dev never built | Run `./deploy.sh dev` first, then promote |
| `... is already at <tag> — nothing to deploy` | Values file already points there | Nothing to do, or pick a different tag |
| `Timed out after <N>s` waiting for ArgoCD | Rollout slow/failing, or auto-sync off | `kubectl -n argocd get app <app>`; `kubectl describe pod` |
| `No SSH key configured for user '<name>'` | No `<UPPERCASE>_SSH_KEY` variable | Add the line at the top of `deploy.sh` |
| `SSH key not found at <path>` | Variable set but file missing | Fix the path / move the `.pem` |
| `No running instance tagged Name=kube-1` | AWS not configured, wrong region, or kube-1 stopped | `aws sts get-caller-identity`; check `AWS_REGION`; start the instance |
| `aws: command not found` | AWS CLI v2 not installed | See [Prerequisites](#prerequisites--aws-cli-setup-one-time) |
| `Permission denied (publickey)` on build | EC2 PEM path/permissions wrong | `chmod 600` the key; fix `<USER>_SSH_KEY` |
| `Permission denied (publickey)` on clone/push | Your **GitHub** SSH isn't set up | Confirm `git push` works outside the script |
| `ImagePullBackOff` after deploy | Pre-pull missed a node | `kubectl describe pod`; manually `ctr pull` on that node |

---

## Image tag convention

| Release type | Example |
|--------------|---------|
| Initial | `v0.1.0` |
| Bug fix | `v0.1.1` |
| Feature | `v0.2.0` |

Never reuse a tag. Kubernetes caches images by tag — a reused tag means stale images
on some nodes with no error.
