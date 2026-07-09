#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest — fresh-cluster bootstrap (defense step 1)
#
#  Turns 4 freshly-launched AWS VMs (Amazon Linux 2023) into a working 4-node
#  kubeadm cluster, end to end, from your laptop. This is the "start a fresh
#  cluster in the cloud" the defense asks for — run it, then deploy infra/app on
#  top (Kustomize/Helm, ArgoCD, ./deploy.sh).
#
#  It automates the manual Phase 2 runbook:
#    - prep all 4 nodes (swap off, kernel modules, sysctl, containerd, k8s repo)
#    - kubeadm init on kube-1 + Calico CNI
#    - join kube-2, ingress, monitoring
#    - remove the control-plane taint, label role=ingress / role=monitoring
#    - copy kubeconfig to this laptop (public IP + insecure-skip-tls-verify)
#
#  Expects 4 running instances tagged Name=kube-1, kube-2, ingress, monitoring.
#
#  Usage:  ./bootstrap.sh [user]
#            ./bootstrap.sh cindy
#            FORCE_RESET=1 ./bootstrap.sh cindy   # kubeadm reset first (re-run)
#
#  Env:
#    AWS_REGION   default eu-west-3
#    K8S_MINOR    kubernetes repo minor, default v1.29
#    FORCE_RESET  1 => run `kubeadm reset -f` on every node before prep
# ─────────────────────────────────────────────────────────────────────────────

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${CYAN}${BOLD}==> $(date +%H:%M:%S)${NC}${CYAN} $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
fail() { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }

# ── Config ──────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-3}"
K8S_MINOR="${K8S_MINOR:-v1.29}"
# Calico is the CNI (matches the long-lived cluster) — it enforces NetworkPolicy,
# which Flannel does not. 192.168.0.0/16 is Calico's manifest default, so kubeadm
# and Calico agree on the pod CIDR with no extra patching. Override CALICO_VERSION
# if you bump Kubernetes (v3.27.x supports k8s 1.29).
POD_CIDR="192.168.0.0/16"              # Calico default
NODES=(kube-1 kube-2 ingress monitoring)
CALICO_VERSION="${CALICO_VERSION:-v3.27.5}"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Per-user SSH keys for EC2 access (same convention as deploy.sh)
CINDY_SSH_KEY="/home/cindy/projects/kubequest-key-pair.pem"
OLIVIER_SSH_KEY="/Users/yolive/Documents/KubeQuest/kubequest-key-pair.pem"

DEPLOY_USER="${1:-$USER}"
USER_KEY_VAR="$(echo "$DEPLOY_USER" | tr '[:lower:]' '[:upper:]')_SSH_KEY"
set +u; SSH_KEY="${!USER_KEY_VAR}"; set -u
[ -z "${SSH_KEY:-}" ] && fail "No SSH key configured for user '$DEPLOY_USER' (expected variable $USER_KEY_VAR)."
[ -f "$SSH_KEY" ]     || fail "SSH key not found at $SSH_KEY"
chmod 600 "$SSH_KEY" 2>/dev/null || true

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o UserKnownHostsFile=/dev/null"

echo -e "\n${BOLD}KubeQuest bootstrap${NC}  region: ${BOLD}${AWS_REGION}${NC}  user: ${BOLD}${DEPLOY_USER}${NC}  k8s: ${BOLD}${K8S_MINOR}${NC}"

# ── AWS lookup: tag -> "PUBLIC PRIVATE" ──────────────────────────────────────
aws_node() {
  aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]" \
    --output text 2>/dev/null
}

# SSH to a node: direct on its public IP, else jump through kube-1's public IP.
# Args: <public_ip> <private_ip> [command...]; stdin is forwarded (for heredocs).
ssh_node() {
  local pub="$1" priv="$2"; shift 2
  if [ -n "$pub" ] && [ "$pub" != "None" ]; then
    ssh $SSH_OPTS ec2-user@"$pub" "$@"
  else
    ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ec2-user@$KUBE1_PUB" ec2-user@"$priv" "$@"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT — resolve all 4 nodes
# ═════════════════════════════════════════════════════════════════════════════
step "[pre-flight] Checking AWS credentials..."
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1 \
  || fail "AWS credentials not configured or expired. Run: aws configure"
ok "AWS reachable in $AWS_REGION"

step "[pre-flight] Resolving node IPs (tags: ${NODES[*]})..."
declare -A PUB PRIV
for n in "${NODES[@]}"; do
  read -r p q <<<"$(aws_node "$n")"
  [ -z "${q:-}" ] || [ "$q" = "None" ] && fail "No running instance tagged Name=$n in $AWS_REGION."
  PUB[$n]="$p"; PRIV[$n]="$q"
  ok "$(printf '%-11s' "$n") public=${p:-<none>}  private=$q"
done
KUBE1_PUB="${PUB[kube-1]}"
[ -z "$KUBE1_PUB" ] || [ "$KUBE1_PUB" = "None" ] && fail "kube-1 must have a public IP to SSH into."

# ═════════════════════════════════════════════════════════════════════════════
#  OPTIONAL RESET — for re-running on already-initialized VMs
# ═════════════════════════════════════════════════════════════════════════════
if [ "${FORCE_RESET:-0}" = "1" ]; then
  step "[reset] FORCE_RESET=1 — running 'kubeadm reset -f' on all nodes..."
  for n in "${NODES[@]}"; do
    echo "    -> $n"
    ssh_node "${PUB[$n]}" "${PRIV[$n]}" 'sudo kubeadm reset -f >/dev/null 2>&1 || true; sudo rm -rf /etc/cni/net.d $HOME/.kube' || true
  done
  ok "Reset complete"
fi

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 1 — prepare every node (swap, modules, sysctl, containerd, kube* pkgs)
# ═════════════════════════════════════════════════════════════════════════════
prep_node() {
  ssh_node "$1" "$2" "K8S_MINOR=$K8S_MINOR bash -s" <<'PREP'
set -euo pipefail
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

sudo yum install -y containerd >/dev/null
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd >/dev/null 2>&1

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes >/dev/null
sudo systemctl enable kubelet >/dev/null 2>&1
echo "  prepped: $(kubeadm version -o short)"
PREP
}

step "[prep] Installing containerd + kube* on all 4 nodes (this takes a few minutes)..."
for n in "${NODES[@]}"; do
  echo "    -> $n"
  prep_node "${PUB[$n]}" "${PRIV[$n]}" || fail "Prep failed on $n"
done
ok "All nodes prepped"

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 2 — kubeadm init on kube-1 + Calico
# ═════════════════════════════════════════════════════════════════════════════
step "[init] Initializing control plane on kube-1 + installing Calico..."
ssh_node "${PUB[kube-1]}" "${PRIV[kube-1]}" "POD_CIDR=$POD_CIDR CALICO_URL=$CALICO_URL bash -s" <<'INIT'
set -euo pipefail
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "  control plane already initialized — skipping kubeadm init"
else
  PRIVATE_IP=$(hostname -I | awk '{print $1}')
  sudo kubeadm init --pod-network-cidr="$POD_CIDR" --apiserver-advertise-address="$PRIVATE_IP"
fi
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl apply -f "$CALICO_URL"
INIT
ok "Control plane up, Calico applied"

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 3 — join the 3 workers
# ═════════════════════════════════════════════════════════════════════════════
step "[join] Generating join command on kube-1..."
JOIN_CMD=$(ssh_node "${PUB[kube-1]}" "${PRIV[kube-1]}" "sudo kubeadm token create --print-join-command" | tr -d '\r')
[ -z "$JOIN_CMD" ] && fail "Could not get a join command from kube-1."
ok "Join command ready"

for n in kube-2 ingress monitoring; do
  step "[join] Joining $n..."
  ssh_node "${PUB[$n]}" "${PRIV[$n]}" "sudo $JOIN_CMD" || fail "Join failed on $n"
  ok "$n joined"
done

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 4 — kubeconfig on this laptop (public IP + insecure TLS)
# ═════════════════════════════════════════════════════════════════════════════
step "[kubeconfig] Copying admin.conf to this machine..."
mkdir -p "$HOME/.kube"
[ -f "$HOME/.kube/config" ] && cp "$HOME/.kube/config" "$HOME/.kube/config.bak.$(date +%s)" && warn "Backed up existing ~/.kube/config"
scp $SSH_OPTS ec2-user@"$KUBE1_PUB":/home/ec2-user/.kube/config "$HOME/.kube/config"

# The API-server cert only covers private IPs, so point at the public IP and
# skip TLS verification (same trick deploy.sh uses on every run).
CLUSTER=$(kubectl config view -o jsonpath='{.clusters[0].name}')
kubectl config unset "clusters.${CLUSTER}.certificate-authority-data" >/dev/null
kubectl config set-cluster "$CLUSTER" --server="https://$KUBE1_PUB:6443" --insecure-skip-tls-verify=true >/dev/null
ok "kubectl targets https://$KUBE1_PUB:6443 (insecure-skip-tls-verify)"

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 5 — wait for Ready, untaint kube-1, label role nodes
# ═════════════════════════════════════════════════════════════════════════════
step "[nodes] Waiting for all 4 nodes to be Ready (timeout 5m)..."
deadline=$(( $(date +%s) + 300 ))
while :; do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${READY:-0}" -ge 4 ] && { echo; ok "$READY/4 nodes Ready"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo; warn "Only ${READY:-0}/${TOTAL:-0} Ready after 5m — check: kubectl get nodes"; break; }
  printf "    ready=%s/%s\r" "${READY:-0}" "${TOTAL:-0}"
  sleep 5
done

step "[nodes] Removing control-plane taint so kube-1 also schedules pods..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
ok "Taint removed"

# Match each role VM to its k8s node by InternalIP (node names are AWS DNS, not tags).
node_for_ip() {
  kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" \
    | awk -v ip="$1" '$2==ip{print $1}'
}
step "[nodes] Labelling worker / role nodes..."
kubectl label nodes --all node-role.kubernetes.io/worker=worker --overwrite >/dev/null 2>&1 || true
for role in ingress monitoring; do
  node=$(node_for_ip "${PRIV[$role]}")
  if [ -n "$node" ]; then
    kubectl label node "$node" role="$role" --overwrite >/dev/null
    ok "role=$role -> $node"
  else
    warn "Could not match $role (private ${PRIV[$role]}) to a k8s node — label it by hand."
  fi
done

# ═════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
echo ""
kubectl get nodes -o wide
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Cluster bootstrapped                            ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Nodes:"   "4 (kube-1 cp+worker, +3 workers)"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "CNI:"     "Calico ($POD_CIDR)"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "API:"     "https://$KUBE1_PUB:6443"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}  Next: deploy tooling (PHASE_3 — Kustomize/Helm, ArgoCD), then the app"
echo -e "  with ./scripts/deploy.sh. Add app.kubequest.local / *.kubequest.local"
echo -e "  to /etc/hosts pointing at the ingress node's public IP.${NC}"
