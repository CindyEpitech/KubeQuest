#!/bin/bash
set -euo pipefail

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${CYAN}${BOLD}==> $(date +%H:%M:%S)${NC}${CYAN} $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
fail() { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }
decode_b64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

# ── Config ──────────────────────────────────────────────────────────────────
KUBE1_NAME_TAG="kube-1"
AWS_REGION="eu-west-3"
REGISTRY="10.0.9.227:5000"
REPO_SSH="git@github.com:CindyEpitech/KubeQuest.git"
REPO_DIR="~/KubeQuest"
APP_URL="http://app.kubequest.local"

# ── Per-user SSH keys ────────────────────────────────────────────────────────
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"

# ── Secrets ────────────────────────────────────────────────────────────────
# Load real values from an ignored .env file, or fall back to the existing
# Kubernetes Secrets when redeploying an already-bootstrapped cluster.
APP_KEY="${APP_KEY:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"

# ── Args ─────────────────────────────────────────────────────────────────────
# Usage:
#   ./deploy.sh                   → user defaults to $USER, auto-increment tag
#   ./deploy.sh cindy             → explicit user, auto-increment tag
#   ./deploy.sh cindy v0.2.0      → explicit user and tag
DEPLOY_USER="${1:-$USER}"
REQUESTED_TAG="${2:-}"

USER_KEY_VAR="$(echo "$DEPLOY_USER" | tr '[:lower:]' '[:upper:]')_SSH_KEY"
set +u
SSH_KEY="${!USER_KEY_VAR}"
set -u

if [ -z "${SSH_KEY:-}" ]; then
  fail "No SSH key configured for user '$DEPLOY_USER' (expected variable $USER_KEY_VAR)."
fi
if [ ! -f "$SSH_KEY" ]; then
  fail "SSH key not found at $SSH_KEY"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

echo -e "\n${BOLD}KubeQuest deploy${NC}  user: ${BOLD}${DEPLOY_USER}${NC}  key: ${SSH_KEY}"

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════
step "[pre-flight] Checking prerequisites..."

# kubectl context
KUBECTL_CTX=$(kubectl config current-context 2>/dev/null || true)
if [ -z "$KUBECTL_CTX" ]; then
  fail "No active kubectl context. Run: kubectl config use-context <name>"
fi
ok "kubectl context: $KUBECTL_CTX"
KUBECTL_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$KUBECTL_CTX\")].context.cluster}" 2>/dev/null || true)
if [ -z "$KUBECTL_CLUSTER" ]; then
  fail "Could not resolve cluster name for kubectl context $KUBECTL_CTX"
fi

# AWS credentials
AWS_ACCOUNT=$(aws sts get-caller-identity --region "$AWS_REGION" --query Account --output text 2>/dev/null || true)
if [ -z "$AWS_ACCOUNT" ]; then
  fail "AWS credentials not configured or expired. Run: aws configure"
fi
ok "AWS account: $AWS_ACCOUNT  region: $AWS_REGION"

# SSH key permissions
chmod 600 "$SSH_KEY" 2>/dev/null || true

# Resolve kube-1 IP (pre-flight — fail fast before doing any real work)
step "[pre-flight] Resolving kube-1 IP (tag: Name=$KUBE1_NAME_TAG)..."
KUBE1_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=$KUBE1_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text 2>/dev/null || echo "")

if [ -z "$KUBE1_IP" ] || [ "$KUBE1_IP" = "None" ]; then
  fail "No running instance tagged Name=$KUBE1_NAME_TAG in $AWS_REGION.\n  Check: aws ec2 describe-instances --region $AWS_REGION"
fi
ok "kube-1 IP: $KUBE1_IP"

kubectl config set-cluster "$KUBECTL_CLUSTER" \
  --server="https://$KUBE1_IP:6443" \
  --insecure-skip-tls-verify=true >/dev/null
ok "kubectl API server updated: https://$KUBE1_IP:6443"

# Helm secrets: prefer .env values, otherwise reuse the current in-cluster secrets.
if [ -z "${APP_KEY:-}" ]; then
  APP_KEY=$(kubectl get secret -n myapp myapp-secret -o jsonpath='{.data.app-key}' 2>/dev/null | decode_b64 || true)
fi
if [ -z "${DB_PASSWORD:-}" ]; then
  DB_PASSWORD=$(kubectl get secret -n myapp myapp-db-secret -o jsonpath='{.data.mysql-password}' 2>/dev/null | decode_b64 || true)
fi
if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
  DB_ROOT_PASSWORD=$(kubectl get secret -n myapp myapp-db-secret -o jsonpath='{.data.mysql-root-password}' 2>/dev/null | decode_b64 || true)
fi

if [ -z "${APP_KEY:-}" ] || [ -z "${DB_PASSWORD:-}" ] || [ -z "${DB_ROOT_PASSWORD:-}" ]; then
  fail "Missing APP_KEY, DB_PASSWORD, or DB_ROOT_PASSWORD. Create $SCRIPT_DIR/.env from .env.example."
fi
ok "Helm secrets loaded without storing them in git"

# Registry reachability (through kube-1)
step "[pre-flight] Checking registry reachability (through kube-1)..."
REGISTRY_RESP=$(ssh -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  ec2-user@"$KUBE1_IP" \
  "curl -s --max-time 5 http://$REGISTRY/v2/ && echo OK" 2>/dev/null || echo "FAIL")
if echo "$REGISTRY_RESP" | grep -q "OK"; then
  ok "Registry $REGISTRY is reachable"
else
  warn "Registry $REGISTRY is not responding — the build step may still succeed if the registry starts in time"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 0 — Resolve image tag
# ═══════════════════════════════════════════════════════════════════════════
step "[0/3] Resolving image tag..."
TAGS_JSON=$(ssh -i "$SSH_KEY" ec2-user@"$KUBE1_IP" \
  "curl -s http://$REGISTRY/v2/myapp/tags/list" 2>/dev/null || echo '{"tags":[]}')
EXISTING_TAGS=$(echo "$TAGS_JSON" | sed 's/.*"tags":\[\([^]]*\)\].*/\1/' \
  | tr ',' '\n' | tr -d '" ' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

if [ -n "$REQUESTED_TAG" ]; then
  if echo "$EXISTING_TAGS" | grep -qx "$REQUESTED_TAG"; then
    fail "Tag '$REQUESTED_TAG' already exists in the registry."
  fi
  IMAGE_TAG="$REQUESTED_TAG"
  ok "Using requested tag: $IMAGE_TAG"
else
  LATEST=$(echo "$EXISTING_TAGS" | sort -V | tail -1)
  if [ -z "$LATEST" ]; then
    IMAGE_TAG="v0.1.0"
  else
    IMAGE_TAG=$(echo "$LATEST" | awk -F. '{print $1"."$2"."$3+1}')
  fi
  ok "Latest tag in registry: ${LATEST:-<none>}"
  ok "Auto-incremented to:    $IMAGE_TAG"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 1 — Build and push image on kube-1
# ═══════════════════════════════════════════════════════════════════════════
step "[1/3] Building and pushing image on kube-1 (tag: $IMAGE_TAG)..."
ssh -i "$SSH_KEY" ec2-user@"$KUBE1_IP" bash <<REMOTE
  set -euo pipefail

  if ! pgrep -x buildkitd > /dev/null; then
    echo "  Starting buildkitd..."
    sudo buildkitd &
    sleep 2
  fi

  ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null

  if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf $REPO_DIR
    echo "  Cloning repo..."
    git clone $REPO_SSH $REPO_DIR
  else
    echo "  Pulling latest code..."
    cd $REPO_DIR && git pull
  fi

  cd $REPO_DIR/sample-app
  echo "  Building image..."
  sudo nerdctl build -t $REGISTRY/myapp:$IMAGE_TAG .
  echo "  Pushing image..."
  sudo nerdctl push --insecure-registry $REGISTRY/myapp:$IMAGE_TAG
  echo "  Registry tags:"
  curl -s http://$REGISTRY/v2/myapp/tags/list
  echo ""
REMOTE
ok "Image $REGISTRY/myapp:$IMAGE_TAG pushed"

# Pre-pull on all cluster nodes
step "[1/3] Pre-pulling image on all nodes..."
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for NODE_IP in $NODE_IPS; do
  echo "    -> $NODE_IP"
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -W %h:%p ec2-user@$KUBE1_IP" \
    ec2-user@"$NODE_IP" \
    "sudo ctr -n k8s.io images pull --plain-http $REGISTRY/myapp:$IMAGE_TAG" || true
done

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 2 — Helm upgrade (rollback-on-failure + install)
# ═══════════════════════════════════════════════════════════════════════════
step "[2/3] Helm upgrade (tag: $IMAGE_TAG)..."
helm upgrade myapp "$SCRIPT_DIR/infra-gitops/charts/myapp" \
  --namespace myapp \
  --install \
  --rollback-on-failure \
  --set image.repository="$REGISTRY/myapp" \
  --set image.tag="$IMAGE_TAG" \
  --set secret.appKey="$APP_KEY" \
  --set secret.dbPassword="$DB_PASSWORD" \
  --set secret.dbRootPassword="$DB_ROOT_PASSWORD" \
  --set mysql.enabled=false \
  --wait \
  --timeout 10m
ok "Helm upgrade complete"

# ═══════════════════════════════════════════════════════════════════════════
#  STEP 3 — Verify rollout
# ═══════════════════════════════════════════════════════════════════════════
step "[3/3] Verifying rollout..."
kubectl rollout status deployment/myapp-myapp -n myapp
kubectl get pods -n myapp -o wide

# ═══════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
READY_REPLICAS=$(kubectl get deployment/myapp-myapp -n myapp \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Deploy complete                                  ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Tag:"      "$IMAGE_TAG"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Replicas:" "${READY_REPLICAS} ready"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "URL:"      "$APP_URL"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
