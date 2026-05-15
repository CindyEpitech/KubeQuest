#!/bin/bash
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────
# Update KUBE1_IP after every reboot (EC2 public IP changes)
KUBE1_IP="35.180.255.74"
SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
REGISTRY="10.0.9.227:5000"
REPO_SSH="git@github.com:CindyEpitech/KubeQuest.git"
REPO_DIR="~/KubeQuest"

# ── Secrets — move to .env and source it if you don't want these in git ────
APP_KEY="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4="
DB_PASSWORD="app_password"
DB_ROOT_PASSWORD="app_root_password"

# ── Image tag — optional argument ──────────────────────────────────────────
# If provided: validate it doesn't already exist in the registry
# If omitted:  auto-increment the patch version from the latest tag
REQUESTED_TAG="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
