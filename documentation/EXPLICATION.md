# KubeQuest — Explication complète du projet

---

## C'est quoi le projet en une phrase ?

Tu dois construire une infrastructure cloud complète sur AWS, avec Kubernetes, pour faire tourner une application web de manière professionnelle — et la présenter en live à tes profs.

---

## Les concepts de base à comprendre d'abord

**AWS (Amazon Web Services)** : c'est un service qui te loue des ordinateurs dans des datacenters Amazon. Tu n'as pas de machine physique — tu loues des VMs (machines virtuelles) accessibles via internet.

**Container** : un container c'est un paquet autonome qui contient une application + tout ce dont elle a besoin pour fonctionner. Contrairement à une installation classique, il tourne de façon isolée et identique peu importe où il est lancé.

**Kubernetes** : un système qui gère automatiquement des centaines de containers — il décide où les faire tourner, les redémarre s'ils crashent, les multiplie si la charge augmente.

**Helm** : un gestionnaire de paquets pour Kubernetes. Comme `apt` ou `pip`, mais pour déployer des applications Kubernetes.

**Kustomize** : un outil pour organiser et assembler des fichiers de configuration Kubernetes sans les dupliquer.

---

## Phase 2 — Monter le cluster Kubernetes

### Objectif

Créer 4 VMs sur AWS et les connecter en un cluster Kubernetes opérationnel.

### Les 4 machines et leurs rôles

|VM|Rôle|
|---|---|
|`kube-1`|Cerveau du cluster (control plane) + peut aussi exécuter des pods|
|`kube-2`|Nœud de travail généraliste|
|`ingress`|Nœud dédié à recevoir le trafic internet entrant|
|`monitoring`|Nœud dédié aux outils d'observation (métriques, logs)|

### Ce que tu as fait concrètement

**Étape 1 — Préparer chaque VM**

Sur chacune des 4 machines, tu as :

- Désactivé le **swap** : Kubernetes l'exige. Le swap est un mécanisme où l'OS utilise le disque comme RAM de secours — Kubernetes a besoin de connaître exactement la mémoire disponible, le swap rend ça imprévisible.
- Activé des **modules kernel** (`overlay`, `br_netfilter`) : ce sont des composants du système Linux qui permettent aux containers de communiquer entre eux via un réseau virtuel.
- Configuré des **paramètres réseau** (`sysctl`) : pour que le trafic réseau entre containers passe correctement par les règles du firewall Linux.
- Installé **containerd** : c'est le moteur qui exécute concrètement les containers. Kubernetes ne fait pas tourner les containers lui-même — il délègue ça à containerd.
- Installé **kubeadm, kubelet, kubectl** :
    - `kubelet` : l'agent Kubernetes qui tourne en permanence sur chaque nœud
    - `kubeadm` : l'outil d'initialisation du cluster
    - `kubectl` : le CLI pour envoyer des commandes au cluster

**Étape 2 — Initialiser le control plane sur kube-1**

`kubeadm init` démarre le cerveau du cluster. Il génère une commande `kubeadm join` que les autres nœuds utilisent pour rejoindre le cluster.

**Étape 3 — Installer le plugin réseau (Flannel)**

Sans réseau, les nœuds restent en état `NotReady`. Flannel crée un réseau virtuel qui permet aux pods de communiquer entre nœuds, même s'ils sont sur des machines différentes.

**Étape 4 — Faire rejoindre les 3 autres nœuds**

Tu executes la commande `kubeadm join` sur kube-2, ingress et monitoring — ils deviennent membres du cluster.

**Étapes 5-7 — Vérification, labels, taint**

- Vérifier que les 4 nœuds sont `Ready`
- Enlever le **taint** du control plane : par défaut Kubernetes refuse de faire tourner des pods sur le nœud control plane pour le protéger. Tu as retiré cette restriction.
- Ajouter des **labels** aux nœuds (`role=ingress`, `role=monitoring`) : ça permet ensuite de dire à Kubernetes "ce pod doit tourner uniquement sur le nœud labelisé ingress".

**Étape 8 — Accès kubectl depuis WSL**

Tu as copié le fichier de configuration (`kubeconfig`) de kube-1 vers ta machine locale, pour pouvoir exécuter `kubectl` directement depuis ton poste sans passer par SSH.

---

## Phase 3 — Outils de gestion du cluster

### Objectif

Déployer 4 composants d'infrastructure sur le cluster, organisés avec Kustomize.

### Structure GitOps

Tu as créé un dépôt Git structuré ainsi :

Plain Text

```
infra-gitops/├── base/               ← manifestes réutilisables│   ├── nginx-ingress/│   ├── kubernetes-dashboard/│   ├── kube-prometheus/│   └── loki/└── overlays/    └── production/     ← assemblage final
```

C'est le principe **GitOps** : toute l'infrastructure est décrite dans des fichiers versionnés dans Git. Pour déployer, tu appliques ces fichiers. Pour rollback, tu reviens à un commit précédent.

---

### Composant 1 — nginx-ingress

**Rôle** : point d'entrée unique de tout le trafic internet vers le cluster.

Sans ingress, chaque service Kubernetes est accessible uniquement en interne. nginx-ingress écoute sur les ports 80 et 443 du nœud `ingress` et route le trafic vers le bon service selon le nom de domaine demandé.

**Pourquoi** `**hostNetwork=true**` : Kubernetes réserve les ports 80/443 au système. En mode normal, les services Kubernetes ne peuvent utiliser que des ports > 30000. `hostNetwork=true` contourne ça — le pod nginx utilise directement le réseau de la VM, et peut donc écouter sur 80/443.

**DaemonSet** : garantit qu'un pod nginx tourne sur chaque nœud labelisé `role=ingress`.

Flux du trafic :

Plain Text

```
Internet → IP publique du nœud ingress :80/443         → pod nginx (hostNetwork)         → service ClusterIP interne         → pod applicatif
```

  

---

### Composant 2 — Kubernetes Dashboard

**Rôle** : interface web pour visualiser et gérer le cluster (pods, deployments, services, logs...).

Tu l'as installé via `kubectl apply -f` avec le manifest officiel v2.7.0 (le repo Helm n'était plus disponible).

**ServiceAccount admin** : Kubernetes a un système de permissions (RBAC). Tu as créé un compte de service `admin-user` avec les droits `cluster-admin` pour pouvoir tout voir dans le dashboard.

**Ingress** : tu as configuré nginx-ingress pour router `dashboard.kubequest.local` vers le service du dashboard. L'annotation `backend-protocol: "HTTPS"` est nécessaire car le dashboard tourne en HTTPS nativement — nginx doit donc faire du proxy HTTPS vers HTTPS et pas HTTP vers HTTPS.

---

### Composant 3 — kube-prometheus (Prometheus + Grafana + Alertmanager)

**Rôle** : collecter et visualiser les métriques du cluster et des applications.

- **Prometheus** : scrape (collecte) les métriques de tous les pods et nœuds toutes les X secondes. Il stocke des séries temporelles (valeur + timestamp).
- **Grafana** : interface de visualisation. Tu crées des dashboards avec des graphiques basés sur les données Prometheus.
- **Alertmanager** : envoie des alertes (email, Slack...) quand des seuils sont dépassés.

Installé via Helm avec `nodeSelector.role=monitoring` pour forcer le déploiement sur le nœud monitoring.

Exposé via deux Ingress : `grafana.kubequest.local` et `prometheus.kubequest.local`.

---

### Composant 4 — Loki + Promtail

**Rôle** : collecte et visualisation des logs (alors que Prometheus gère les métriques).

- **Promtail** : agent déployé en DaemonSet sur tous les nœuds. Il lit les logs de chaque container et les envoie à Loki.
- **Loki** : stocke et indexe les logs. Requêtable depuis Grafana.

La distinction importante : **Prometheus = métriques chiffrées** (CPU à 80%, 5 requêtes/sec), **Loki = logs textuels** (les lignes de log des applications).

---

### Problèmes rencontrés en Phase 3

- **ValidatingWebhookConfiguration** : nginx-ingress installe un webhook de validation qui bloque certaines ressources si le pod n'est pas encore prêt. Solution : supprimer `ingress-nginx-admission`.
- **504 Gateway Timeout** : causé par `ssl-passthrough` qui ne fonctionnait pas avec le dashboard. Solution : remplacer par `backend-protocol: "HTTPS"`.
- **Duplicate Grafana datasource** : `loki-stack` crée automatiquement un ConfigMap datasource. En ajouter un second avec `isDefault: true` crashe Grafana. Solution : vérifier et corriger le ConfigMap existant.

---

## Phase 4 — Helm Chart applicatif + Registry privé

### Objectif

Convertir une application docker-compose en déploiement Kubernetes complet via un Helm Chart, et la servir depuis un registry privé hébergé sur kube-1.

---

### Registry privé (REGISTRY.md)

**Pourquoi un registry privé** : les images Docker sont stockées dans des registries. Docker Hub est public. Ici, l'image de l'application est custom — tu la construis toi-même et tu la stockes dans un registry que tu héberges sur kube-1.

**Stack** :

- `registry:2` : le serveur de registry, lancé comme container nerdctl sur kube-1, port 5000
- `nerdctl` : équivalent de `docker` mais compatible avec `containerd` (le runtime utilisé par Kubernetes)
- `buildkit` : moteur de build d'images, requis par nerdctl

**Flux** :

Plain Text

```
WSL → scp code source → kube-1kube-1 → nerdctl build → image localekube-1 → nerdctl push → registry (10.0.9.227:5000)kube-2/ingress/monitoring → containerd pull → depuis registry
```

Chaque nœud est configuré avec un fichier `hosts.toml` pour accepter le registry en HTTP (sans TLS) sur `10.0.9.227:5000`.

---

### Helm Chart (charts/myapp/)

**Helm** génère des manifestes Kubernetes à partir de templates paramétrables. Le chart contient :

|Fichier|Rôle|
|---|---|
|`secret.yaml`|Stocke APP_KEY et mots de passe DB — Kubernetes encode en base64 et les injecte comme variables d'environnement|
|`configmap.yaml`|Variables de config non sensibles|
|`deployment.yaml`|2 réplicas de l'app Laravel, anti-affinity (les 2 pods ne peuvent pas être sur le même nœud), initContainer qui attend que MySQL soit prêt|
|`service.yaml`|ClusterIP — expose l'app en interne au cluster|
|`ingress.yaml`|Route `app.kubequest.local` vers le service|
|`hpa.yaml`|HorizontalPodAutoscaler — scale de 2 à 6 réplicas automatiquement si CPU > seuil|
|`pvc.yaml`|PersistentVolumeClaim — volume de stockage pour les backups|
|`cronjob-backup.yaml`|Job quotidien qui fait un `mysqldump` et conserve 7 jours de backups|
|`mysql.yaml`|Deployment MySQL 8.0 officiel + Service + PVC|

**Problèmes rencontrés** :

- Pas de StorageClass par défaut → installer `local-path-provisioner` (Rancher)
- DNS cassé dans le cluster avec Calico sur AWS → rediriger CoreDNS vers `8.8.8.8`
- Image officielle MySQL incompatible avec le chart Bitnami → désactiver Bitnami et créer un `mysql.yaml` custom
- Readiness probe sur `/up` retourne 404 → changer en `/`
- Laravel retourne 500 → migrations non exécutées → `artisan migrate --force`

---

## Ce qui reste à faire (selon le sujet)

Le sujet mentionne encore :

- **OPA** (Open Policy Agent) : webhook de validation qui contrôle ce qui peut être déployé dans le cluster (ex: bloquer les pods sans `limits`)
- **Dex + oauth-proxy** : authentification SSO pour protéger le dashboard, Grafana et Prometheus
- **cert-manager + Let's Encrypt** : certificats TLS automatiques (bonus)
- **ArgoCD** : déploiement GitOps automatisé — surveille le repo Git et applique les changements automatiquement (bonus)

---

## Ce que tu dois démontrer à la soutenance

1. Démarrer un cluster from scratch
2. Déployer tout avec `kubectl apply`, `helm install`, `kubectl apply -k`
3. Démontrer l'auto-scaling (envoyer du trafic massif → les pods se multiplient)
4. Démontrer un rollback (déployer une version cassée → Kubernetes détecte l'échec → retour automatique à la version précédente)