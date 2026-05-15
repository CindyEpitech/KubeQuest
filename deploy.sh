#!/bin/bash
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────
# kube-1 public IP is resolved dynamically from AWS (see "Resolving kube-1 IP" below)
KUBE1_NAME_TAG="kube-1"
AWS_REGION="eu-west-3"
REGISTRY="10.0.9.227:5000"
REPO_SSH="git@github.com:CindyEpitech/KubeQuest.git"
REPO_DIR="~/KubeQuest"

# ── Per-user SSH keys ──────────────────────────────────────────────────────
# Add one variable per collaborator: <UPPERCASE_USERNAME>_SSH_KEY
# Selected at runtime via the first argument (./deploy.sh cindy) or $USER.
CINDY_SSH_KEY="$HOME/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"
 
# TEAMMATE_SSH_KEY="$HOME/projects/teammate-key-pair.pem"

# ── Secrets — move to .env and source it if you don't want these in git ────
APP_KEY="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4="
DB_PASSWORD="app_password"
DB_ROOT_PASSWORD="app_root_password"

# ── Args ───────────────────────────────────────────────────────────────────
# Usage:
#   ./deploy.sh                   → user defaults to $USER, auto-increment tag
#   ./deploy.sh cindy             → explicit user, auto-increment tag
#   ./deploy.sh cindy v0.2.0      → explicit user and tag
DEPLOY_USER="${1:-$USER}"
REQUESTED_TAG="${2:-}"

# Resolve <UPPERCASE_USERNAME>_SSH_KEY via indirect expansion
USER_KEY_VAR="${DEPLOY_USER^^}_SSH_KEY"
SSH_KEY="${!USER_KEY_VAR:-}"

if [ -z "$SSH_KEY" ]; then
  echo "ERROR: No SSH key configured for user '$DEPLOY_USER' (expected variable $USER_KEY_VAR)."
  echo "  Add a line at the top of deploy.sh, e.g.:"
  echo "    ${USER_KEY_VAR}=\"\$HOME/projects/${DEPLOY_USER}-key-pair.pem\""
  exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY (user: $DEPLOY_USER)"
  exit 1
fi
echo "Deploying as user: $DEPLOY_USER  (key: $SSH_KEY)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "==> Resolving kube-1 public IP from AWS (tag: Name=$KUBE1_NAME_TAG, region: $AWS_REGION)..."
KUBE1_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=$KUBE1_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text 2>/dev/null || echo "")

if [ -z "$KUBE1_IP" ] || [ "$KUBE1_IP" = "None" ]; then
  echo "  ERROR: Could not resolve a running instance tagged Name=$KUBE1_NAME_TAG in $AWS_REGION."
  echo "  Check:"
  echo "    - aws sts get-caller-identity      (are credentials configured?)"
  echo "    - aws ec2 describe-instances --region $AWS_REGION  (does the instance exist and is it running?)"
  exit 1
fi
echo "  kube-1 public IP: $KUBE1_IP"

echo ""
echo "==> [0/3] Resolving image tag..."
# Query the registry through kube-1 (registry is on internal IP)
TAGS_JSON=$(ssh -i "$SSH_KEY" ec2-user@"$KUBE1_IP" "curl -s http://$REGISTRY/v2/myapp/tags/list" 2>/dev/null || echo '{"tags":[]}')
EXISTING_TAGS=$(echo "$TAGS_JSON" | sed 's/.*"tags":\[\([^]]*\)\].*/\1/' | tr ',' '\n' | tr -d '" ' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

if [ -n "$REQUESTED_TAG" ]; then
  # Validate: tag must not already exist
  if echo "$EXISTING_TAGS" | grep -qx "$REQUESTED_TAG"; then
    echo "  ERROR: tag '$REQUESTED_TAG' already exists in the registry."
    echo "  Existing tags:"
    echo "$EXISTING_TAGS" | sed 's/^/    /'
    exit 1
  fi
  IMAGE_TAG="$REQUESTED_TAG"
  echo "  Using requested tag: $IMAGE_TAG"
else
  # Auto-increment: find highest vX.Y.Z and bump the patch
  LATEST=$(echo "$EXISTING_TAGS" | sort -V | tail -1)
  if [ -z "$LATEST" ]; then
    IMAGE_TAG="v0.1.0"
  else
    IMAGE_TAG=$(echo "$LATEST" | awk -F. '{print $1"."$2"."$3+1}')
  fi
  echo "  Latest tag in registry: ${LATEST:-<none>}"
  echo "  Auto-incremented to:    $IMAGE_TAG"
fi

echo ""
echo "==> [1/3] Building and pushing image on kube-1 (tag: $IMAGE_TAG)..."
ssh -i "$SSH_KEY" ec2-user@"$KUBE1_IP" bash <<REMOTE
  set -euo pipefail

  # Start buildkitd if not already running
  if ! pgrep -x buildkitd > /dev/null; then
    echo "  Starting buildkitd..."
    sudo buildkitd &
    sleep 2
  fi

  # Trust GitHub's host key (needed on fresh EC2 instances)
  ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null

  # Clone repo if not a valid git repo, otherwise pull latest
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

  echo "  Verifying registry..."
  curl -s http://$REGISTRY/v2/myapp/tags/list
  echo ""
REMOTE

# Pre-pull image on all cluster nodes via ProxyJump through kube-1
# WSL holds the key — no need for kube-1 to have SSH access to workers
echo "  Pre-pulling image on all nodes..."
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for NODE_IP in $NODE_IPS; do
  echo "    -> $NODE_IP"
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o "ProxyCommand=ssh -i $SSH_KEY -o StrictHostKeyChecking=no -W %h:%p ec2-user@$KUBE1_IP" \
    ec2-user@"$NODE_IP" \
    "sudo ctr -n k8s.io images pull --plain-http $REGISTRY/myapp:$IMAGE_TAG" || true
done

echo ""
echo "==> [2/3] Running helm upgrade (tag: $IMAGE_TAG)..."
helm upgrade myapp "$SCRIPT_DIR/infra-gitops/charts/myapp" \
  --namespace myapp \
  --set image.repository="$REGISTRY/myapp" \
  --set image.tag="$IMAGE_TAG" \
  --set secret.appKey="$APP_KEY" \
  --set secret.dbPassword="$DB_PASSWORD" \
  --set secret.dbRootPassword="$DB_ROOT_PASSWORD" \
  --set mysql.enabled=false \
  --wait \
  --timeout 5m

echo ""
echo "==> [3/3] Verifying rollout..."
kubectl rollout status deployment/myapp-myapp -n myapp
kubectl get pods -n myapp -o wide

echo ""
echo "Deploy complete — myapp:$IMAGE_TAG is live."
