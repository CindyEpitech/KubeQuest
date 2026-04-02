# WSL — Accès kubectl au cluster

## Contexte

Connexion de WSL (machine locale) au cluster Kubernetes sur kube-1 (AWS EC2) pour pouvoir lancer des commandes `kubectl` sans passer par SSH.

---

## Prérequis

- Clé SSH `kubequest-key-pair.pem` présente dans `/home/cindy/projects/KubeQuest/`
- kube-1 accessible publiquement sur `15.237.208.164`
- Port 6443 ouvert dans le security group AWS (Inbound TCP 6443 `0.0.0.0/0`)

---

## Étapes

### 1. Installer kubectl sur WSL

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

### 2. Copier le kubeconfig depuis kube-1

```bash
mkdir -p ~/.kube
scp -i /home/cindy/projects/KubeQuest/kubequest-key-pair.pem \
  ec2-user@15.237.208.164:/home/ec2-user/.kube/config \
  ~/.kube/config
```

### 3. Remplacer l'IP privée par l'IP publique

Le kubeconfig généré par kubeadm contient l'IP privée (`10.0.9.227`) inaccessible depuis l'extérieur.

```bash
sed -i 's|https://10.0.9.227:6443|https://15.237.208.164:6443|' ~/.kube/config
```

### 4. Désactiver la vérification TLS

Le certificat de l'API server ne couvre que les IPs privées (`10.0.9.227`, `10.96.0.1`), pas l'IP publique — ce qui provoque une erreur x509.

```bash
kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true
```

### 5. Vérifier

```bash
kubectl get nodes
```

---

## Notes

- L'IP publique de kube-1 change à chaque redémarrage de l'instance EC2 (pas d'Elastic IP). Répéter les étapes 3 et 4 après chaque redémarrage.
- Le flag `--insecure-skip-tls-verify` est acceptable pour ce projet. En production, il faudrait régénérer le certificat API server avec l'IP publique dans les SANs.

---

## Redémarrage de l'instance (procédure)

Après chaque redémarrage des VMs :

```bash
# Récupère la nouvelle IP publique depuis la console AWS
NEW_IP=<nouvelle-ip>

# Met à jour le kubeconfig
sed -i "s|https://.*:6443|https://$NEW_IP:6443|" ~/.kube/config
kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true

kubectl get nodes
```