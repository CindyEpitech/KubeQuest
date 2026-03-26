# KubeQuest — Phase 2: Kubernetes Cluster Bootstrap
> kubeadm | Amazon Linux 2023 | kube-1 + kube-2

---

## Overview

Initialize a 2-node Kubernetes cluster using `kubeadm` on Amazon Linux 2023.
`kube-1` acts as the control plane + worker, `kube-2` as an additional worker.

> This guide uses `yum`/`dnf` — the correct package manager for Amazon Linux 2023.
> SSH user is `ec2-user`, not `ubuntu`.

---

## Prerequisites

- Phase 1 complete — all 4 VMs running and SSH accessible
- Run each section on the correct machine as indicated

```bash
# SSH into nodes
ssh -i ~/.ssh/kubequest.pem ec2-user@<node-ip>
```

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

---

### Install containerd

```bash
sudo yum install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup — required for kubeadm
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

Verify:
```bash
sudo systemctl status containerd
```

---

### Install kubeadm, kubelet, kubectl

Add the Kubernetes yum repository:

```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```

Install the packages:

```bash
sudo yum install -y kubelet kubeadm kubectl \
  --disableexcludes=kubernetes

# Enable kubelet on boot
sudo systemctl enable kubelet
```

Pin versions to prevent accidental upgrades:
```bash
sudo yum versionlock add kubelet kubeadm kubectl
# If versionlock plugin is not installed:
sudo yum install -y 'dnf-command(versionlock)'
sudo yum versionlock add kubelet kubeadm kubectl
```

Verify:
```bash
kubeadm version
kubectl version --client
```

---

## Step 2 — Initialize Control Plane (kube-1 only)

SSH into `kube-1`:
```bash
ssh -i ~/.ssh/kubequest.pem ec2-user@$KUBE1_IP
```

Get the private IP:
```bash
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "Private IP: $PRIVATE_IP"
```

Initialize the cluster:
```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=$PRIVATE_IP
```

> Use the **private IP**, not the public one. It stays stable across restarts.

### Set up kubectl for ec2-user
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Save the join command
At the end of `kubeadm init` output you will see something like:
```
kubeadm join <private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

**Copy and save this — you need it for Step 4.**

If you lose it:
```bash
kubeadm token create --print-join-command
```

---

## Step 3 — Install CNI Plugin (kube-1 only)

### Option A — Flannel (recommended)
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### Option B — Calico
```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

Verify pods are coming up:
```bash
kubectl get pods -n kube-flannel   # Flannel
kubectl get pods -n kube-system    # Calico
```

---

## Step 4 — Join Worker Node (kube-2 only)

SSH into `kube-2`:
```bash
ssh -i ~/.ssh/kubequest.pem ec2-user@$KUBE2_IP
```

Run the join command from Step 2:
```bash
sudo kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Step 5 — Verify the Cluster (kube-1)

Back on `kube-1`:
```bash
kubectl get nodes
```

Expected output (may take 1-2 minutes):
```
NAME     STATUS   ROLES           AGE   VERSION
kube-1   Ready    control-plane   5m    v1.29.x
kube-2   Ready    <none>          2m    v1.29.x
```

```bash
kubectl get pods --all-namespaces
```

---

## Step 6 — Allow Scheduling on Control Plane (optional)

```bash
kubectl taint nodes kube-1 node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Step 6 bis — Label Both Nodes as Workers

After removing the taint, kube-1 still shows no `worker` role in `kubectl get nodes`. This is purely cosmetic — add the label manually to both nodes:


```bash
# kube-2
kubectl label node i-06cfda93115a3e14d.eu-west-3.compute.internal node-role.kubernetes.io/worker=worker

# kube-1 (control plane + worker)
kubectl label node i-0f5f389df39671199.eu-west-3.compute.internal \ node-role.kubernetes.io/worker=worker
```

Expected output after labeling:

```
NAME       STATUS   ROLES                  AGE   VERSION
kube-1     Ready    control-plane,worker   35m   v1.29.x
kube-2     Ready    worker                 10m   v1.29.x
```

---

## Step 7 — Copy kubeconfig to Your Local Machine

```bash
# On your local machine
mkdir -p ~/.kube

scp -i ~/.ssh/kubequest.pem ec2-user@$KUBE1_IP:/home/ec2-user/.kube/config ~/.kube/config

# Replace private IP with public IP so you can reach it from outside
sed -i "s|server: https://.*:6443|server: https://$KUBE1_IP:6443|" ~/.kube/config
```

Verify from local:
```bash
kubectl get nodes
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `apt-get not found` | You are on Amazon Linux — use `yum` instead |
| `No match for argument: apt-transport-https` | Not needed on Amazon Linux — skip it |
| containerd not found | Run `sudo yum install -y containerd` |
| Node stays `NotReady` | CNI not installed — run Step 3 |
| `connection refused` on port 6443 | Check security group has port 6443 open |
| Join token expired | Run `kubeadm token create --print-join-command` on kube-1 |
| Pods stuck in `Pending` | Control plane taint active — run Step 6 |
| kubectl from laptop fails | Check public IP in kubeconfig matches current kube-1 IP |

---

## Next Step

Once both nodes show `Ready`, proceed to:
**[Phase 3 — Cluster Tooling](./PHASE_3_CLUSTER_TOOLING.md)**