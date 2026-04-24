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

# ── Image tag — required argument ───────────────────────────────────────────
IMAGE_TAG="${1:?Usage: ./deploy.sh <image-tag>  e.g. ./deploy.sh v0.1.1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Pre-pull image on all cluster nodes (workaround for HTTP registry)
# Node IPs fetched from WSL where kubectl is configured
echo "  Pre-pulling image on all nodes..."
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
ssh -i "$SSH_KEY" ec2-user@"$KUBE1_IP" bash <<PREPULL
  for NODE_IP in $NODE_IPS; do
    echo "    -> \$NODE_IP"
    ssh -o StrictHostKeyChecking=no ec2-user@\$NODE_IP \
      "sudo ctr -n k8s.io images pull --plain-http $REGISTRY/myapp:$IMAGE_TAG" 2>/dev/null || true
  done
PREPULL

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
