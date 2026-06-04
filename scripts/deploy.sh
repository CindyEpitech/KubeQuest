#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest GitOps deploy
#
#  This script does NOT apply anything to the cluster directly. It builds the
#  image (dev) or promotes an existing one (prod), bumps the image tag in the
#  right Helm values file, and pushes to Git. ArgoCD watches the repo and rolls
#  the change out on its own — the git push IS the deploy.
#
#  Usage:  ./deploy.sh <dev|prod> [user] [tag]
#
#    ./deploy.sh dev               build develop, auto-increment tag -> myapp-dev
#    ./deploy.sh dev cindy v0.2.0  build develop with an explicit tag
#    ./deploy.sh prod              promote the tag currently on dev -> myapp
#    ./deploy.sh prod cindy v0.1.9 promote a specific (already-built) tag
#
#  dev  → builds the image on kube-1, pushes it, bumps values-dev.yaml,
#         pushes to `develop`. ArgoCD app `myapp-dev` syncs into ns myapp-dev.
#  prod → does NOT rebuild. Promotes the image tag dev is already running
#         (or an explicit tag) into values-production.yaml, pushes to `main`.
#         ArgoCD app `myapp` syncs into ns myapp.
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
REPO_SSH="git@github.com:CindyEpitech/KubeQuest.git"
REPO_DIR="/home/ec2-user/KubeQuest"       # build checkout on kube-1
CHART_DIR="infra-gitops/charts/myapp"
DEPLOY_DEPLOYMENT="myapp-myapp"           # <release>-<chart>, same in both namespaces
ARGO_NS="argocd"
SYNC_TIMEOUT=300                          # seconds to wait for ArgoCD to converge

# ── Per-user SSH keys (EC2 access — NOT GitHub) ──────────────────────────────
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"

# ── Args ─────────────────────────────────────────────────────────────────────
ENV="${1:-}"
DEPLOY_USER="${2:-$USER}"
REQUESTED_TAG="${3:-}"

usage() {
  cat <<'EOF'

Usage: ./deploy.sh <dev|prod> [user] [tag]

  ./deploy.sh dev               build develop, auto-increment tag -> myapp-dev
  ./deploy.sh dev cindy v0.2.0  build develop with an explicit tag
  ./deploy.sh prod              promote the tag currently on dev   -> myapp
  ./deploy.sh prod cindy v0.1.9 promote a specific (already-built) tag

  dev  builds the image on kube-1, bumps values-dev.yaml, pushes develop.
  prod does NOT rebuild — promotes an existing tag into values-production.yaml,
       pushes main. ArgoCD rolls out both; the git push is the deploy.
EOF
  exit 1
}

case "$ENV" in
  dev)
    BRANCH="develop"
    VALUES_FILE="$CHART_DIR/values-dev.yaml"
    ARGO_APP="myapp-dev"; APP_NS="myapp-dev"
    APP_URL="http://app-dev.kubequest.local"
    DO_BUILD=true ;;
  prod)
    BRANCH="main"
    VALUES_FILE="$CHART_DIR/values-production.yaml"
    ARGO_APP="myapp"; APP_NS="myapp"
    APP_URL="http://app.kubequest.local"
    DO_BUILD=false ;;
  *)
    warn "First argument must be 'dev' or 'prod'."; usage ;;
esac

# ── Resolve SSH key for the chosen user ──────────────────────────────────────
USER_KEY_VAR="$(echo "$DEPLOY_USER" | tr '[:lower:]' '[:upper:]')_SSH_KEY"
set +u; SSH_KEY="${!USER_KEY_VAR}"; set -u
[ -z "${SSH_KEY:-}" ] && fail "No SSH key configured for user '$DEPLOY_USER' (expected variable $USER_KEY_VAR)."
[ -f "$SSH_KEY" ]     || fail "SSH key not found at $SSH_KEY"
chmod 600 "$SSH_KEY" 2>/dev/null || true

echo -e "\n${BOLD}KubeQuest deploy${NC}  env: ${BOLD}${ENV}${NC}  branch: ${BOLD}${BRANCH}${NC}  user: ${BOLD}${DEPLOY_USER}${NC}"

# Run a command on kube-1
k1() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@"$KUBE1_IP" "$@"; }

# List semver image tags currently in the registry (reachable only via kube-1)
registry_tags() {
  k1 "curl -s http://$REGISTRY/v2/myapp/tags/list" 2>/dev/null \
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

if [ "$DO_BUILD" = true ]; then
  # dev: build a brand-new image, so pick a tag that does NOT exist yet
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
else
  # prod: promote an image that already exists. Default = whatever dev runs.
  if [ -n "$REQUESTED_TAG" ]; then
    IMAGE_TAG="$REQUESTED_TAG"
  else
    IMAGE_TAG="$(git show "origin/develop:$CHART_DIR/values-dev.yaml" \
      | sed -n -E 's/^[[:space:]]*tag:[[:space:]]*//p' | head -1 | tr -d '"')"
    [ -z "$IMAGE_TAG" ] && fail "Could not read the dev image tag from origin/develop:$CHART_DIR/values-dev.yaml"
    ok "Tag currently on dev: $IMAGE_TAG"
  fi
  echo "$EXISTING_TAGS" | grep -qx "$IMAGE_TAG" \
    || fail "Tag '$IMAGE_TAG' is not in the registry — build it on dev first ('./deploy.sh dev')."
  ok "Promoting existing tag: $IMAGE_TAG"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  BUILD (dev only) — build & push the image on kube-1, pre-pull on all nodes
# ═════════════════════════════════════════════════════════════════════════════
if [ "$DO_BUILD" = true ]; then
  step "[build] Building & pushing image on kube-1 (tag: $IMAGE_TAG)..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@"$KUBE1_IP" bash <<REMOTE
    set -euo pipefail
    if ! pgrep -x buildkitd > /dev/null; then echo "  Starting buildkitd..."; sudo buildkitd & sleep 2; fi
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null
    if [ ! -d "$REPO_DIR/.git" ]; then rm -rf "$REPO_DIR"; echo "  Cloning repo..."; git clone "$REPO_SSH" "$REPO_DIR"; fi
    cd "$REPO_DIR"
    git fetch origin --quiet
    git checkout "$BRANCH"
    git reset --hard "origin/$BRANCH"
    cd "$REPO_DIR/sample-app"
    echo "  Building image..."
    sudo nerdctl build -t $REGISTRY/myapp:$IMAGE_TAG .
    echo "  Pushing image..."
    sudo nerdctl push --insecure-registry $REGISTRY/myapp:$IMAGE_TAG
REMOTE
  ok "Image $REGISTRY/myapp:$IMAGE_TAG pushed"

  step "[build] Pre-pulling image on all nodes..."
  NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  for NODE_IP in $NODE_IPS; do
    echo "    -> $NODE_IP"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -W %h:%p ec2-user@$KUBE1_IP" \
      ec2-user@"$NODE_IP" \
      "sudo ctr -n k8s.io images pull --plain-http $REGISTRY/myapp:$IMAGE_TAG" || true
  done
fi

# ═════════════════════════════════════════════════════════════════════════════
#  COMMIT THE TAG BUMP — this is the actual "deploy"
# ═════════════════════════════════════════════════════════════════════════════
step "[git] Bumping $(basename "$VALUES_FILE") -> $IMAGE_TAG and pushing $BRANCH..."
sed -i.bak -E "s|^([[:space:]]*tag:[[:space:]]*).*|\1$IMAGE_TAG|" "$VALUES_FILE"
rm -f "$VALUES_FILE.bak"
if git diff --quiet -- "$VALUES_FILE"; then
  fail "$(basename "$VALUES_FILE") is already at $IMAGE_TAG — nothing to deploy."
fi
git add "$VALUES_FILE"
git commit -q -m "chore(deploy): $ENV image tag -> $IMAGE_TAG"
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
echo -e "${GREEN}${BOLD}║  Deploy complete (via GitOps)                     ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Env:"      "$ENV ($ARGO_APP)"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Tag:"      "$IMAGE_TAG"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Branch:"   "$BRANCH (pushed)"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Replicas:" "${READY} ready"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "URL:"      "$APP_URL"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"

if [ "$ENV" = "prod" ]; then
  echo -e "${YELLOW}  Note: prod promoted only the image tag. If chart/template changes"
  echo -e "  were made on develop, merge them into main as well.${NC}"
fi
