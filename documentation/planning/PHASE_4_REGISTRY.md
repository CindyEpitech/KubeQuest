# KubeQuest — Private Registry sur kube-1
> nerdctl + registry:2 | sans Kubernetes

---

## Concept

On fait tourner un registry de containers **directement sur la VM kube-1**, comme un service système classique.

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

Ce registry est accessible par tous les nodes via le réseau privé AWS — sans passer par internet.

**nerdctl** = le CLI containerd. Remplace Docker sur Amazon Linux 2023. Mêmes commandes : `nerdctl build`, `nerdctl run`, `nerdctl push`.

---

## Étape 0 — Installer Nerdctl

```bash
# Télécharge nerdctl
curl -LO https://github.com/containerd/nerdctl/releases/download/v2.0.2/nerdctl-2.0.2-linux-amd64.tar.gz

# Extrait et installe
sudo tar -C /usr/local/bin -xzf nerdctl-2.0.2-linux-amd64.tar.gz nerdctl

# Vérifie
nerdctl --version
```

## Étape 1 — Lancer le registry sur kube-1

SSH sur kube-1 :
```bash
ssh -i ~/.ssh/kubequest ec2-user@35.181.55.161
```

Lancer le registry :
```bash
# Lance registry:2 comme un container nerdctl en arrière-plan
# -d           : arrière-plan (detached)
# --name       : nom du container
# --restart always : redémarre automatiquement si la VM reboot
# -p 5000:5000 : expose le port 5000 de la VM vers le port 5000 du container
# -v           : stocke les images sur le disque de la VM (dans /var/lib/registry)
sudo nerdctl run -d \
  --name registry \
  --restart always \
  -p 5000:5000 \
  -v /var/lib/registry:/var/lib/registry \
  registry:2
```

Vérifier que ça tourne :
```bash
# Liste les containers nerdctl actifs
sudo nerdctl ps

# Teste le registry — doit retourner {}
curl http://localhost:5000/v2/
```

---

## Étape 2 — Configurer containerd sur les 4 nodes

containerd (le moteur de containers de Kubernetes) doit savoir que ce registry existe et qu'il peut lui faire confiance sans TLS.

À faire sur **kube-1, kube-2, ingress et monitoring** :

```bash
# Crée le dossier de config pour ce registry spécifique
sudo mkdir -p /etc/containerd/certs.d/10.0.9.227:5000

# Crée le fichier de config
# skip_verify = true : accepte le registry sans TLS (HTTP simple)
sudo tee /etc/containerd/certs.d/10.0.9.227:5000/hosts.toml <<EOF
server = "http://10.0.9.227:5000"

[host."http://10.0.9.227:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Redémarre containerd pour prendre en compte la config
sudo systemctl restart containerd
```

> L'adresse `10.0.9.227` est l'IP privée de kube-1 — les autres nodes l'atteignent via le réseau interne AWS.

---

## Étape 3 — Builder et pusher l'image depuis kube-1

Le code source de l'app doit être présent sur kube-1. Soit tu clones ton repo, soit tu copias les fichiers avec `scp`.

```bash
# Clone le repo sur kube-1 (une seule fois)
git clone https://github.com/ton-org/ton-repo.git
cd ton-repo

# Tag = hash court du commit Git (ex: a3f9c12)
# Unique par commit, traçable, même convention que le CI
export IMAGE_TAG=$(git rev-parse --short HEAD)

# Build l'image depuis le Dockerfile
# -t = tag complet : adresse-registry/nom-image:tag
sudo nerdctl build -t 10.0.9.227:5000/myapp:$IMAGE_TAG .

# Push vers le registry
# --insecure-registry : autorise le HTTP (pas de TLS)
sudo nerdctl push --insecure-registry 10.0.9.227:5000/myapp:$IMAGE_TAG

# Vérifie que l'image est bien stockée dans le registry
curl http://10.0.9.227:5000/v2/myapp/tags/list
# doit retourner {"name":"myapp","tags":["a3f9c12"]}
```

---

## Étape 4 — Déployer avec Helm

```bash
# Depuis ta machine locale (kubectl configuré)
export IMAGE_TAG=a3f9c12  # le tag que tu as pushé

helm install myapp ./charts/myapp \
  --namespace myapp \
  --set image.repository=10.0.9.227:5000/myapp \
  --set image.tag=$IMAGE_TAG \
  --set secret.appKey="base64:DJYTvaRkEZ/YcQsX3TMpB0iCjgme2rhlIOus9A1hnj4=" \
  --set secret.dbPassword=app_password \
  --set secret.dbRootPassword=app_root_password \
  --wait --timeout 5m
```

Kubernetes va puller `10.0.9.227:5000/myapp:a3f9c12` depuis chaque node — containerd sait où aller grâce à la config faite à l'étape 2.

---

## Workflow pour les mises à jour

```bash
# Sur kube-1 — après chaque modification du code
cd ton-repo
git pull
export IMAGE_TAG=$(git rev-parse --short HEAD)
sudo nerdctl build -t 10.0.9.227:5000/myapp:$IMAGE_TAG .
sudo nerdctl push --insecure-registry 10.0.9.227:5000/myapp:$IMAGE_TAG

# Depuis ta machine locale — upgrade le déploiement
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=$IMAGE_TAG \
  --wait --timeout 5m
```

---

## Troubleshooting

| Problème | Cause | Fix |
|----------|-------|-----|
| `curl localhost:5000/v2/` ne répond pas | Registry pas démarré | `sudo nerdctl ps` — relancer si absent |
| Pull échoue sur les workers | containerd pas reconfiguré | Vérifier `/etc/containerd/certs.d/10.0.9.227:5000/hosts.toml` sur le node |
| `connection refused` depuis un autre node | Port 5000 bloqué | Vérifier le Security Group AWS — port 5000 ouvert en interne (`10.0.0.0/16`) |
| Image non trouvée après push | Mauvais tag | `curl http://10.0.9.227:5000/v2/myapp/tags/list` pour voir les tags disponibles |
| Registry perdu après reboot | `--restart always` manquant | Relancer avec le flag `--restart always` |