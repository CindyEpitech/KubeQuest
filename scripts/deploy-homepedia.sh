#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest GitOps deploy — HomePedia frontend (develop)
#
#  Same model as deploy.sh, but for the HomePedia Next.js frontend. It does NOT
#  apply anything to the cluster directly: it builds the frontend image on
#  kube-1, bumps the image tag in the chart's values-dev.yaml (in KubeQuest), and
#  pushes to `develop`. ArgoCD app `homepedia-dev` watches the repo and rolls the
#  change out into ns homepedia-dev on its own — the git push IS the deploy.
#
#  HomePedia is its OWN repo (CindyEpitech/HomePedia). The
#  frontend image is built from THAT repo on kube-1; KubeQuest only holds the
#  Helm chart + GitOps wiring. kube-1's deploy key only reaches KubeQuest, so the
#  app repo is cloned over HTTPS using a fine-grained PAT (Contents: read) kept
#  on kube-1 at ~/.homepedia_token (chmod 600, never committed). Create it once:
#    printf '%s' '<fine-grained-PAT>' > ~/.homepedia_token && chmod 600 ~/.homepedia_token
#
#  Only the frontend is built here. The in-cluster Postgres/Mongo use stock
#  images mirrored into the registry once (see infra-gitops/argocd/README.md);
#  the ETL/PySpark/analysis jobs stay on local Docker.
#
#  Usage:  ./deploy-homepedia.sh [user] [tag]
#
#    ./deploy-homepedia.sh cindy         build develop, auto-increment the tag
#    ./deploy-homepedia.sh cindy v0.2.0  build develop with an explicit tag
#
#  PROD is automated the same way as myapp: merging develop into main fires the
#  "Promote dev tag to production" Action for whichever values-dev.yaml changed.
# ─────────────────────────────────────────────────────────────────────────────

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${CYAN}${BOLD}==> $(date +%H:%M:%S)${NC}${CYAN} $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
fail() { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }

# ── Config ──────────────────────────────────────────────────────────────────
KUBE1_NAME_TAG="kube-1"
AWS_REGION="eu-west-3"
REGISTRY="10.0.9.227:5000"
IMAGE_NAME="homepedia-frontend"          # registry repo for the frontend image
REPO_SSH="git@github.com:CindyEpitech/KubeQuest.git"   # infra/GitOps repo (values bump)
CHART_DIR="infra-gitops/charts/homepedia"
# HomePedia app lives in its OWN repo — the frontend image is built from there.
# kube-1's deploy key is scoped to KubeQuest only, so the app repo is cloned over
# HTTPS using a fine-grained PAT (Contents: read) stored on kube-1, NOT committed.
HOMEPEDIA_REPO_HTTPS="https://github.com/CindyEpitech/HomePedia.git"
# Same URL with the username injected; the PAT is supplied by GIT_ASKPASS, not here.
HOMEPEDIA_AUTH_URL="${HOMEPEDIA_REPO_HTTPS/https:\/\//https://x-access-token@}"
HOMEPEDIA_TOKEN_FILE="\$HOME/.homepedia_token"  # on kube-1; expanded remotely
HOMEPEDIA_DIR="/home/ec2-user/homepedia"  # build checkout on kube-1
HOMEPEDIA_REF="${HOMEPEDIA_REF:-main}"    # branch/tag of the app repo to build
FRONTEND_SUBDIR="apps/frontend"           # within the homepedia repo
DOCKERFILE="Dockerfile.production"        # frontend has dev + prod Dockerfiles
DEPLOY_DEPLOYMENT="homepedia-homepedia"  # <release>-<chart>, same in both namespaces
ARGO_NS="argocd"
SYNC_TIMEOUT=300                         # seconds to wait for ArgoCD to converge

# ── Per-user SSH keys (EC2 access — NOT GitHub) ──────────────────────────────
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"

# ── Args ─────────────────────────────────────────────────────────────────────
DEPLOY_USER="${1:-$USER}"
REQUESTED_TAG="${2:-}"

usage() {
  cat <<'EOF'

Usage: ./deploy-homepedia.sh [user] [tag]

  ./deploy-homepedia.sh cindy         build develop, auto-increment the tag
  ./deploy-homepedia.sh cindy v0.2.0  build develop with an explicit tag

  Builds the HomePedia frontend image on kube-1, bumps the chart's
  values-dev.yaml, pushes develop. ArgoCD (homepedia-dev) rolls it out;
  the git push is the deploy.

  To reach prod, merge develop -> main: the "Promote dev tag to production"
  Action opens a PR bumping values-production.yaml to the dev tag; merge it
  and ArgoCD rolls out prod.
EOF
  exit 1
}

BRANCH="develop"
VALUES_FILE="$CHART_DIR/values-dev.yaml"
ARGO_APP="homepedia-dev"; APP_NS="homepedia-dev"
APP_URL="http://homepedia-dev.kubequest.local"

# ── Resolve SSH key for the chosen user ──────────────────────────────────────
USER_KEY_VAR="$(echo "$DEPLOY_USER" | tr '[:lower:]' '[:upper:]')_SSH_KEY"
set +u; SSH_KEY="${!USER_KEY_VAR}"; set -u
[ -z "${SSH_KEY:-}" ] && fail "No SSH key configured for user '$DEPLOY_USER' (expected variable $USER_KEY_VAR)."
[ -f "$SSH_KEY" ]     || fail "SSH key not found at $SSH_KEY"
chmod 600 "$SSH_KEY" 2>/dev/null || true

echo -e "\n${BOLD}KubeQuest deploy — HomePedia${NC}  branch: ${BOLD}${BRANCH}${NC}  user: ${BOLD}${DEPLOY_USER}${NC}"

# Run a command on kube-1
k1() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@"$KUBE1_IP" "$@"; }

# List semver image tags currently in the registry (reachable only via kube-1)
registry_tags() {
  k1 "curl -s http://$REGISTRY/v2/$IMAGE_NAME/tags/list" 2>/dev/null \
    | sed 's/.*"tags":\[\([^]]*\)\].*/\1/' | tr ',' '\n' | tr -d '" ' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# ═════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═════════════════════════════════════════════════════════════════════════════
step "[pre-flight] Checking prerequisites..."

KUBECTL_CTX=$(kubectl config current-context 2>/dev/null || true)
[ -z "$KUBECTL_CTX" ] && fail "No active kubectl context. Run: kubectl config use-context <name>"
ok "kubectl context: $KUBECTL_CTX"
KUBECTL_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$KUBECTL_CTX\")].context.cluster}" 2>/dev/null || true)
[ -z "$KUBECTL_CLUSTER" ] && fail "Could not resolve cluster name for kubectl context $KUBECTL_CTX"

AWS_ACCOUNT=$(aws sts get-caller-identity --region "$AWS_REGION" --query Account --output text 2>/dev/null || true)
[ -z "$AWS_ACCOUNT" ] && fail "AWS credentials not configured or expired. Run: aws configure"
ok "AWS account: $AWS_ACCOUNT  region: $AWS_REGION"

step "[pre-flight] Resolving kube-1 IP (tag: Name=$KUBE1_NAME_TAG)..."
KUBE1_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=$KUBE1_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text 2>/dev/null || echo "")
if [ -z "$KUBE1_IP" ] || [ "$KUBE1_IP" = "None" ]; then
  fail "No running instance tagged Name=$KUBE1_NAME_TAG in $AWS_REGION."
fi
ok "kube-1 IP: $KUBE1_IP"

kubectl config set-cluster "$KUBECTL_CLUSTER" \
  --server="https://$KUBE1_IP:6443" \
  --insecure-skip-tls-verify=true >/dev/null
ok "kubectl API server updated: https://$KUBE1_IP:6443"

step "[pre-flight] Checking registry reachability (through kube-1)..."
if k1 "curl -s --max-time 5 http://$REGISTRY/v2/ >/dev/null && echo OK" 2>/dev/null | grep -q OK; then
  ok "Registry $REGISTRY is reachable"
else
  warn "Registry $REGISTRY is not responding — build/promote may fail"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  CLONE — all git work happens in a throwaway clone, never your working tree
# ═════════════════════════════════════════════════════════════════════════════
step "[git] Cloning $BRANCH into a scratch dir..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet "$REPO_SSH" "$WORK"
cd "$WORK"
git checkout --quiet "$BRANCH"
ok "Clone ready at $WORK"

# ═════════════════════════════════════════════════════════════════════════════
#  RESOLVE IMAGE TAG
# ═════════════════════════════════════════════════════════════════════════════
step "[tag] Resolving image tag..."
EXISTING_TAGS="$(registry_tags)"

# Build a brand-new image, so pick a tag that does NOT exist yet.
if [ -n "$REQUESTED_TAG" ]; then
  echo "$EXISTING_TAGS" | grep -qx "$REQUESTED_TAG" && fail "Tag '$REQUESTED_TAG' already exists in the registry."
  IMAGE_TAG="$REQUESTED_TAG"
else
  LATEST="$(echo "$EXISTING_TAGS" | sort -V | tail -1)"
  if [ -z "$LATEST" ]; then
    IMAGE_TAG="v0.1.0"
  else
    IMAGE_TAG="$(echo "$LATEST" | awk -F. '{print $1"."$2"."$3+1}')"
  fi
  ok "Latest tag in registry: ${LATEST:-<none>}"
fi
ok "New tag to build: $IMAGE_TAG"

# ═════════════════════════════════════════════════════════════════════════════
#  BUILD — build & push the image on kube-1, pre-pull on all nodes
# ═════════════════════════════════════════════════════════════════════════════
step "[build] Building & pushing image on kube-1 (tag: $IMAGE_TAG)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@"$KUBE1_IP" bash <<REMOTE
  set -euo pipefail
  if ! pgrep -x buildkitd > /dev/null; then
    echo "  Starting buildkitd..."
    # Fully detach from the SSH channel (redirect all fds + nohup), otherwise
    # the backgrounded daemon keeps the ssh session open and the deploy hangs.
    sudo sh -c 'nohup buildkitd >/tmp/buildkitd.log 2>&1 < /dev/null &'
    sleep 3
  fi
  ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null

  # App repo is private and in another org — clone over HTTPS with a fine-grained
  # PAT read from $HOMEPEDIA_TOKEN_FILE. GIT_ASKPASS feeds the token as the
  # password so it never appears in process args or in .git/config.
  TOKEN_FILE="$HOMEPEDIA_TOKEN_FILE"
  if [ ! -s "\$TOKEN_FILE" ]; then
    echo "  ERROR: PAT file \$TOKEN_FILE missing/empty on kube-1." >&2
    echo "         Create it: printf '%s' '<fine-grained-PAT>' > \$TOKEN_FILE && chmod 600 \$TOKEN_FILE" >&2
    exit 1
  fi
  ASKPASS="\$(mktemp)"
  trap 'rm -f "\$ASKPASS"' EXIT
  printf '#!/bin/sh\ncat "%s"\n' "\$TOKEN_FILE" > "\$ASKPASS"
  chmod +x "\$ASKPASS"
  export GIT_ASKPASS="\$ASKPASS" GIT_TERMINAL_PROMPT=0
  # Username embedded; password comes from GIT_ASKPASS (the token).
  AUTH_URL="$HOMEPEDIA_AUTH_URL"

  if [ ! -d "$HOMEPEDIA_DIR/.git" ]; then rm -rf "$HOMEPEDIA_DIR"; echo "  Cloning homepedia app repo (HTTPS+PAT)..."; git clone "\$AUTH_URL" "$HOMEPEDIA_DIR"; fi
  cd "$HOMEPEDIA_DIR"
  git remote set-url origin "\$AUTH_URL"   # token-free URL; GIT_ASKPASS supplies it
  git fetch origin --quiet
  git checkout "$HOMEPEDIA_REF"
  git reset --hard "origin/$HOMEPEDIA_REF"
  cd "$HOMEPEDIA_DIR/$FRONTEND_SUBDIR"
  echo "  Building image ($DOCKERFILE from homepedia@$HOMEPEDIA_REF)..."
  sudo nerdctl build -f $DOCKERFILE -t $REGISTRY/$IMAGE_NAME:$IMAGE_TAG .
  echo "  Pushing image..."
  sudo nerdctl push --insecure-registry $REGISTRY/$IMAGE_NAME:$IMAGE_TAG
REMOTE
ok "Image $REGISTRY/$IMAGE_NAME:$IMAGE_TAG pushed"

step "[build] Pre-pulling image on all nodes..."
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for NODE_IP in $NODE_IPS; do
  echo "    -> $NODE_IP"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -W %h:%p ec2-user@$KUBE1_IP" \
    ec2-user@"$NODE_IP" \
    "sudo ctr -n k8s.io images pull --plain-http $REGISTRY/$IMAGE_NAME:$IMAGE_TAG" || true
done

# ═════════════════════════════════════════════════════════════════════════════
#  COMMIT THE TAG BUMP — this is the actual "deploy"
# ═════════════════════════════════════════════════════════════════════════════
step "[git] Bumping $(basename "$VALUES_FILE") -> $IMAGE_TAG and pushing $BRANCH..."
# Only bump the tag under the frontend.image block (the chart has several image
# blocks). Anchor on the repository line so we hit the right one.
python3 - "$VALUES_FILE" "$IMAGE_NAME" "$IMAGE_TAG" <<'PY'
import re, sys
path, image_name, new_tag = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
# Find the repository line that ends in the frontend image name, then bump the
# next `tag:` after it.
repo_re = re.compile(r'^\s*repository:\s*\S*' + re.escape(image_name) + r'\s*$')
tag_re  = re.compile(r'^(\s*)tag:\s*.*$')
i = 0
done = False
while i < len(lines):
    if repo_re.match(lines[i]):
        for j in range(i + 1, min(i + 5, len(lines))):
            m = tag_re.match(lines[j])
            if m:
                lines[j] = f"{m.group(1)}tag: {new_tag}\n"
                done = True
                break
        break
    i += 1
if not done:
    sys.exit("Could not find the frontend image tag to bump in %s" % path)
with open(path, 'w') as f:
    f.writelines(lines)
PY
if git diff --quiet -- "$VALUES_FILE"; then
  fail "$(basename "$VALUES_FILE") is already at $IMAGE_TAG — nothing to deploy."
fi
git add "$VALUES_FILE"
git commit -q -m "chore(deploy): homepedia dev image tag -> $IMAGE_TAG"
git push -q origin "$BRANCH"
ok "Pushed tag bump to origin/$BRANCH"

# ═════════════════════════════════════════════════════════════════════════════
#  WAIT FOR ARGOCD — nudge a refresh, then poll until Synced + Healthy on the tag
# ═════════════════════════════════════════════════════════════════════════════
step "[argocd] Nudging $ARGO_APP to sync..."
kubectl -n "$ARGO_NS" annotate app "$ARGO_APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
ok "Refresh requested"

step "[argocd] Waiting for $ARGO_APP: Synced + Healthy on $IMAGE_TAG (timeout ${SYNC_TIMEOUT}s)..."
deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
while :; do
  SYNC=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
  HEALTH=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")
  IMGS=$(kubectl -n "$APP_NS" get deploy "$DEPLOY_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null || echo "")
  if echo "$IMGS" | grep -q ":$IMAGE_TAG" && [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
    echo
    ok "ArgoCD reports Synced + Healthy on $IMAGE_TAG"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    warn "Timed out after ${SYNC_TIMEOUT}s — last seen: sync=$SYNC health=$HEALTH"
    warn "ArgoCD may still converge. Inspect: kubectl -n argocd get app $ARGO_APP"
    exit 1
  fi
  printf "    sync=%-12s health=%-12s\r" "$SYNC" "$HEALTH"
  sleep 5
done

# ═════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
READY=$(kubectl -n "$APP_NS" get deploy "$DEPLOY_DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  HomePedia deploy complete (via GitOps)          ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "App:"      "$ARGO_APP"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Tag:"      "$IMAGE_TAG"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Branch:"   "$BRANCH (pushed)"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Replicas:" "${READY} ready"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "URL:"      "$APP_URL"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"

echo -e "${YELLOW}  Next: to promote to prod, merge develop -> main. The"
echo -e "  \"Promote dev tag to production\" Action opens a PR bumping"
echo -e "  values-production.yaml to $IMAGE_TAG; merge it and ArgoCD rolls out prod.${NC}"
