# KubeQuest — Private Registry sur kube-1
> registry:2 | nerdctl | buildkit

---

## Concept

Un registry de containers qui tourne directement sur la VM kube-1, accessible par tous les nodes via le réseau privé AWS (10.0.9.227:5000).

```
┌─────────────────────────────────────────┐
│  kube-1 (VM EC2)                        │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  registry:2 (nerdctl container) │    │
│  │  écoute sur 0.0.0.0:5000        │    │
│  └─────────────────────────────────┘    │
│                                         │
│  IP privée : 10.0.9.227                 │
└─────────────────────────────────────────┘
         ↑ push (nerdctl)
         │
         │ pull (containerd)
         ↓
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│    kube-2    │  │   ingress    │  │  monitoring  │
│ 10.0.9.165   │  │ 10.0.10.228  │  │ 10.0.2.176   │
└──────────────┘  └──────────────┘  └──────────────┘
```

Un registry de containers qui tourne directement sur la VM kube-1, accessible par tous les nodes via le réseau privé AWS (`10.0.9.227:5000`).

```
┌──────────────────────────────┐
│     WSL (local machine)      │
│                              │
│  sample-app-master/          │
│  ├─ source code              │
│  └─ Dockerfile               │
└──────────────┬───────────────┘
               │
               │ scp
               ▼
┌──────────────────────────────┐
│   kube-1 (10.0.9.227)        │
│                              │
│  ┌────────────────────────┐  │
│  │ registry:2             │  │
│  │ (nerdctl, port 5000)   │  │
│  └────────────────────────┘  │
│                              │
│  nerdctl build + push        │
└──────────────┬───────────────┘
               │
               │ pull (AWS private network)
               ▼
┌──────────────────────────────┐
│  kube-2                      │
│  ├─ ingress                  │
│  └─ monitoring               │
└──────────────────────────────┘
```

---

## Étape 1 — Installer nerdctl sur kube-1

```bash
# SSH sur kube-1
ssh -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem ec2-user@35.181.55.161

# Télécharge nerdctl
curl -LO https://github.com/containerd/nerdctl/releases/download/v2.0.2/nerdctl-2.0.2-linux-amd64.tar.gz

# Installe dans /usr/local/bin
sudo tar -C /usr/local/bin -xzf nerdctl-2.0.2-linux-amd64.tar.gz nerdctl

# Vérifie
nerdctl --version
```

---

## Étape 2 — Installer buildkit sur kube-1

nerdctl a besoin de buildkit pour builder des images.

```bash
# Télécharge buildkit
curl -LO https://github.com/moby/buildkit/releases/download/v0.13.2/buildkit-v0.13.2.linux-amd64.tar.gz

# Installe dans /usr/local
sudo tar -C /usr/local -xzf buildkit-v0.13.2.linux-amd64.tar.gz

# Démarre buildkitd en arrière-plan
sudo buildkitd &

# Attends 2 secondes et vérifie
sleep 2
sudo buildctl debug workers
# Doit afficher 2 workers avec leurs plateformes
```

> buildkitd doit être relancé à chaque reboot de kube-1 avec `sudo buildkitd &`

---

## Étape 3 — Lancer le registry sur kube-1

```bash
# Lance registry:2 comme container nerdctl en arrière-plan
# --restart always : redémarre si la VM reboot
# -p 5000:5000    : expose le port 5000 de la VM
# -v              : stocke les images sur le disque de la VM
sudo nerdctl run -d \
  --name registry \
  --restart always \
  -p 5000:5000 \
  -v /var/lib/registry:/var/lib/registry \
  registry:2

# Vérifie que le registry répond
curl http://localhost:5000/v2/
# Doit retourner {}
```

---

## Étape 4 — Configurer containerd sur les 4 nodes

À faire sur **kube-1, kube-2, ingress et monitoring**.

```bash
# Crée le dossier de config pour ce registry
sudo mkdir -p /etc/containerd/certs.d/10.0.9.227:5000

# Crée le fichier hosts.toml
# skip_verify = true : accepte HTTP sans TLS
sudo tee /etc/containerd/certs.d/10.0.9.227:5000/hosts.toml <<EOF
server = "http://10.0.9.227:5000"

[host."http://10.0.9.227:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Redémarre containerd pour prendre en compte la config
sudo systemctl restart containerd
```

---

## Étape 5 — Copier le code source depuis WSL vers kube-1

Depuis **WSL** (machine locale) :

```bash
scp -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem \
  -r /home/cindy/projects/KubeQuest/sample-app-master \
  ec2-user@35.181.55.161:~/
```

---

## Étape 6 — Builder et pusher l'image

Sur **kube-1** :

```bash
cd ~/sample-app-master

# Définir le tag de l'image
export IMAGE_TAG=v0.1.0

# Builder l'image depuis le Dockerfile
sudo nerdctl build -t 10.0.9.227:5000/myapp:$IMAGE_TAG .

# Pusher vers le registry
sudo nerdctl push --insecure-registry 10.0.9.227:5000/myapp:$IMAGE_TAG

# Vérifier que l'image est bien stockée
curl http://10.0.9.227:5000/v2/myapp/tags/list
# Doit retourner {"name":"myapp","tags":["v0.1.0"]}
```

---

## Workflow pour les mises à jour

```bash
# 1. Depuis WSL — copier les nouveaux fichiers
scp -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem \
  -r /home/cindy/projects/KubeQuest/sample-app-master \
  ec2-user@35.181.55.161:~/

# 2. Sur kube-1 — rebuilder et pusher
cd ~/sample-app-master
export IMAGE_TAG=v0.1.1   # incrémenter le tag
sudo nerdctl build -t 10.0.9.227:5000/myapp:$IMAGE_TAG .
sudo nerdctl push --insecure-registry 10.0.9.227:5000/myapp:$IMAGE_TAG

# 3. Depuis WSL — mettre à jour le déploiement Helm
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=$IMAGE_TAG \
  --wait --timeout 5m
```

---

## Après un reboot de kube-1

buildkitd ne persiste pas — il faut le relancer :

```bash
sudo buildkitd &
sleep 2
sudo buildctl debug workers
```

Le registry lui redémarre automatiquement grâce à `--restart always`.

---

## Troubleshooting

| Problème | Fix |
|----------|-----|
| `nerdctl: command not found` | Refaire l'étape 1 |
| `buildkitd` not found au build | Relancer `sudo buildkitd &` |
| `curl localhost:5000/v2/` ne répond pas | `sudo nerdctl ps` — relancer le registry si absent |
| Pull échoue sur un worker | Vérifier `/etc/containerd/certs.d/10.0.9.227:5000/hosts.toml` sur ce node |
| `lstat Containerfile: no such file` | Tu n'es pas dans le bon dossier — `cd ~/sample-app-master` |
| Image non trouvée après push | `curl http://10.0.9.227:5000/v2/myapp/tags/list` pour vérifier |