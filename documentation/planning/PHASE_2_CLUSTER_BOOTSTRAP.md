# KubeQuest — Phase 2: Kubernetes Cluster Bootstrap
> kubeadm | Amazon Linux 2023 | 4 nodes

---

## Overview

Set up a 4-node Kubernetes cluster:

| VM | Role |
|----|------|
| `kube-1` | Control plane + worker |
| `kube-2` | Worker |
| `ingress` | Worker (nginx-ingress will run here) |
| `monitoring` | Worker (Prometheus, Grafana, Loki will run here) |

> All 4 VMs must join the cluster. The `ingress` and `monitoring` VMs
> are not standalone machines — their tools run as Kubernetes pods and
> must be scheduled on nodes.

---

## Important Notes

- Package manager is `yum` — this is **Amazon Linux 2023**, not Ubuntu
- SSH user is `ec2-user`
- Do **not** use `apt-get`, `apt`, or `ubuntu` anywhere
- Node names in Kubernetes will show as long AWS internal DNS names like
  `i-0f5f389df39671199.eu-west-3.compute.internal` — this is normal

---

## Step 1 — Prepare ALL 4 VMs

> Run every command in this step on **kube-1, kube-2, ingress, and monitoring**.
> SSH into each one and run the same block.

```bash
ssh -i ~/.ssh/kubequest.pem ec2-user@<vm-ip>
```

### 1a — Disable swap
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### 1b — Load kernel modules
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### 1c — Configure sysctl
```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 1d — Install containerd
```bash
sudo yum install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Required for kubeadm to work correctly
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

Verify:
```bash
sudo systemctl status containerd
# Should show: active (running)
```

### 1e — Add Kubernetes repo
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

### 1f — Install kubeadm, kubelet, kubectl
```bash
sudo yum install -y kubelet kubeadm kubectl \
  --disableexcludes=kubernetes

sudo systemctl enable kubelet
```

Verify:
```bash
kubeadm version
kubectl version --client
```

---

## Step 2 — Initialize Control Plane (kube-1 ONLY)

SSH into kube-1:
```bash
ssh -i ~/.ssh/kubequest.pem ec2-user@$KUBE1_IP
```

Get the private IP of kube-1:
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

> This takes 2-3 minutes. At the end you will see a `kubeadm join` command — **copy it**.

### Set up kubectl on kube-1
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Save the join command
The output of `kubeadm init` ends with something like:
```
kubeadm join 10.0.1.x:6443 --token xxxxx \
  --discovery-token-ca-cert-hash sha256:xxxxx
```

Save it. If you lose it, regenerate it on kube-1:
```bash
kubeadm token create --print-join-command
```

---

## Step 3 — Install CNI Plugin (kube-1 ONLY)

Without a CNI plugin, nodes will stay `NotReady`. Install Flannel:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Verify it's running:
```bash
kubectl get pods -n kube-flannel
# Should show Running after ~1 minute
```

---

## Step 4 — Join All 3 Worker Nodes

SSH into each of **kube-2, ingress, and monitoring** one by one
and run the join command you saved from Step 2:

```bash
# On kube-2
ssh -i ~/.ssh/kubequest.pem ec2-user@$KUBE2_IP
sudo kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

# On ingress
ssh -i ~/.ssh/kubequest.pem ec2-user@$INGRESS_IP
sudo kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

# On monitoring
ssh -i ~/.ssh/kubequest.pem ec2-user@$MONITORING_IP
sudo kubeadm join <kube-1-private-ip>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Step 5 — Verify All Nodes Are Ready (kube-1)

Back on kube-1, check all 4 nodes appear:

```bash
kubectl get nodes
```

Expected (wait 1-2 minutes if some show `NotReady`):
```
NAME                                              STATUS   ROLES           AGE   VERSION
i-0f5f389df39671199.eu-west-3.compute.internal   Ready    control-plane   10m   v1.29.x
i-06cfda93115a3e14d.eu-west-3.compute.internal   Ready    <none>          5m    v1.29.x
i-00c62469a3d8ca2d4.eu-west-3.compute.internal   Ready    <none>          3m    v1.29.x
i-03fe23d890b52c5e1.eu-west-3.compute.internal   Ready    <none>          2m    v1.29.x
```

---

## Step 6 — Remove Control Plane Taint (kube-1)

By default kube-1 refuses to run regular pods. Remove that restriction:

```bash
kubectl taint nodes <kube-1-node-name> \
  node-role.kubernetes.io/control-plane:NoSchedule-
```

> Get the node name from `kubectl get nodes`

---

## Step 7 — Label All Nodes

Labels tell Kubernetes where to schedule specific pods.
Run all of these from kube-1:

```bash
# Replace each <node-name> with the actual name from kubectl get nodes

# kube-1: control plane + worker
kubectl label node i-0f5f389df39671199.eu-west-3.compute.internal node-role.kubernetes.io/worker=worker

# kube-2: regular worker
kubectl label node i-06cfda93115a3e14d.eu-west-3.compute.internal node-role.kubernetes.io/worker=worker

# ingress node: nginx-ingress will be forced here
kubectl label node i-00c62469a3d8ca2d4.eu-west-3.compute.internal node-role.kubernetes.io/worker=worker
kubectl label node i-00c62469a3d8ca2d4.eu-west-3.compute.internal role=ingress

# monitoring node: Prometheus, Grafana, Loki will be forced here
kubectl label node i-03fe23d890b52c5e1.eu-west-3.compute.internal node-role.kubernetes.io/worker=worker
kubectl label node i-03fe23d890b52c5e1.eu-west-3.compute.internal role=monitoring
```

Verify labels:
```bash
kubectl get nodes --show-labels
```

Expected result:
```
NAME        STATUS   ROLES                  AGE   VERSION
kube-1      Ready    control-plane,worker   ...   v1.29.x
kube-2      Ready    worker                 ...   v1.29.x
ingress     Ready    worker                 ...   v1.29.x
monitoring  Ready    worker                 ...   v1.29.x
```

---

## Step 8 — Copy kubeconfig to Your Local Machine

So you can run `kubectl` from your laptop without SSHing into kube-1:

```bash
# On your local machine
mkdir -p ~/.kube

scp -i ~/.ssh/kubequest.pem \
  ec2-user@$KUBE1_IP:/home/ec2-user/.kube/config \
  ~/.kube/config

# Replace private IP with public IP
sed -i "s|server: https://.*:6443|server: https://$KUBE1_IP:6443|" ~/.kube/config

# Test it works
kubectl get nodes
```

---

## Final Check

```bash
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl cluster-info
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `apt-get not found` | Use `yum` — this is Amazon Linux, not Ubuntu |
| Node stays `NotReady` | Flannel not installed yet — run Step 3 |
| Join token expired | Run `kubeadm token create --print-join-command` on kube-1 |
| kube-1 not scheduling pods | Taint still active — run Step 6 |
| kubectl from laptop fails | Update kubeconfig with new public IP after restart |
| containerd not found | Run `sudo yum install -y containerd` |

---

## Next Step

**[Phase 3 — Cluster Tooling](./PHASE_3_CLUSTER_TOOLING.md)**