# KubeQuest — Phase 2: Kubernetes Cluster Bootstrap
> kubeadm | kube-1 + kube-2

---

## Overview

Initialize a 2-node Kubernetes cluster using `kubeadm`.
`kube-1` acts as the control plane + worker, `kube-2` as an additional worker.

---

## Prerequisites

- Phase 1 complete — all 4 VMs running and SSH accessible
- SSH into `kube-1` and `kube-2` before starting

---

## Step 1 — Prepare Both Nodes (run on kube-1 AND kube-2)

### Disable swap
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### Load required kernel modules
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### Configure sysctl
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### Install containerd
```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

### Install kubeadm, kubelet, kubectl
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

## Step 2 — Initialize Control Plane (kube-1 only)

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=<kube-1-private-ip>
```

> Use the **private IP** of kube-1, not the public one.

### Set up kubectl access
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Save the join command
At the end of `kubeadm init` output, you'll see something like:
```bash
kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```
**Copy and save this — you'll need it for kube-2.**

If you lose it, regenerate with:
```bash
kubeadm token create --print-join-command
```

---

## Step 3 — Install CNI Plugin (kube-1 only)

### Option A — Flannel (simpler)
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### Option B — Calico (more features)
```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

> Both work fine for this project. Flannel is recommended for simplicity.

---

## Step 4 — Join Worker Node (kube-2 only)

SSH into `kube-2` and run the join command saved from Step 2:

```bash
sudo kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Step 5 — Verify the Cluster (kube-1)

```bash
kubectl get nodes
```

Expected output (may take 1-2 minutes to become Ready):
```
NAME     STATUS   ROLES           AGE   VERSION
kube-1   Ready    control-plane   5m    v1.29.x
kube-2   Ready    <none>          2m    v1.29.x
```

```bash
# Check all system pods are running
kubectl get pods -n kube-system
```

---

## Step 6 — Allow Scheduling on Control Plane (optional)

By default, the control plane node is tainted to prevent workload scheduling.
For this project, we want it to also run workloads:

```bash
kubectl taint nodes kube-1 node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Step 7 — Share kubeconfig with Your Teammate

```bash
# On kube-1, print the kubeconfig
cat $HOME/.kube/config
```

Copy the content and share it securely with Person B.
On their local machine:

```bash
mkdir -p ~/.kube
# Paste the content into:
nano ~/.kube/config
```

> Make sure to replace `server: https://127.0.0.1:6443` with `server: https://<kube-1-public-ip>:6443`

---

## Verify Everything Works

```bash
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl cluster-info
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Node stays `NotReady` | CNI plugin not installed yet — check Step 3 |
| `connection refused` on port 6443 | Security group missing port 6443 — check Phase 1 |
| Join token expired | Regenerate with `kubeadm token create --print-join-command` |
| Pods stuck in `Pending` | Control plane taint active — run Step 6 |

---

## Next Step

Once both nodes show `Ready`, proceed to:
**[Phase 3 — Cluster Tooling](./PHASE_3_CLUSTER_TOOLING.md)**