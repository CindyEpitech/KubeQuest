## C'est quoi un Helm chart ?

Un chart c'est un dossier de templates YAML. Helm prend ces templates, y injecte des valeurs depuis `values.yaml`, et produit des manifests Kubernetes normaux. C'est juste un système de templating glorifié — mais ça permet de paramétrer un déploiement complet en une commande.

---

## `Chart.yaml` — la carte d'identité

yaml

```yaml
dependencies:
  - name: mysql
    version: "11.x.x"
    repository: https://charts.bitnami.com/bitnami
```

Ça dit à Helm "mon chart a besoin d'un autre chart (MySQL de Bitnami) en dépendance". Quand tu fais `helm dependency update`, il télécharge ce chart et le met dans un dossier `charts/`. Quand tu déploies, MySQL est déployé automatiquement avec l'app.

---

## `values.yaml` — tous les paramètres au même endroit

C'est le fichier que tu modifies pour changer le comportement du chart sans toucher aux templates. Par exemple :

- `replicaCount: 2` → combien de pods app
- `image.tag` → quelle version de l'image
- `ingress.host` → sur quel hostname exposer l'app
- `secret.appKey` → la Laravel APP_KEY (injectée au moment du déploiement, jamais committée)

Les templates lisent ces valeurs avec la syntaxe `{{ .Values.truc }}`.

---

## `_helpers.tpl` — les fonctions réutilisables

Ce fichier définit des "fonctions" Helm appelées partout dans les autres templates :

- `myapp.name` → retourne `myapp`
- `myapp.fullname` → retourne `release-myapp` (évite les collisions si tu déploies plusieurs fois)
- `myapp.labels` → les labels standards Kubernetes (`app.kubernetes.io/name`, etc.) — copié-collé dans chaque ressource
- `myapp.mysqlHost` → retourne le hostname DNS du service MySQL (`release-mysql`) — comme ça si tu changes le nom de la release, ça se met à jour partout

---

## `secret.yaml` — les données sensibles

Crée deux Secrets Kubernetes :

**`myapp-secret`** → contient `APP_KEY` de Laravel. C'est la clé de chiffrement de l'app — si elle change, toutes les sessions et cookies existants deviennent invalides.

**`myapp-db-secret`** → contient `mysql-password` et `mysql-root-password`. Ces noms de clés sont **imposés par Bitnami** — leur chart MySQL cherche exactement ces noms. Et via `existingSecret: myapp-db-secret` dans `values.yaml`, on dit à Bitnami "ne crée pas ton propre Secret, utilise celui-là".

Les valeurs sont encodées en base64 par Helm (`b64enc`), comme Kubernetes l'exige pour les Secrets.

---

## `configmap.yaml` — la config non-sensible

Contient toutes les variables d'environnement qui ne sont **pas** des secrets : `APP_ENV`, `APP_URL`, `DB_HOST`, `DB_PORT`, etc.

`DB_HOST` est généré dynamiquement via `myapp.mysqlHost` — ça pointe vers le service Kubernetes du MySQL Bitnami, qui est accessible en interne via DNS.

Il y a aussi un deuxième ConfigMap `myapp-mysql-init` — c'est l'équivalent du volume `./mysql-init` dans le docker-compose. Bitnami MySQL exécute les scripts SQL qu'il trouve dans ce ConfigMap au premier démarrage.

---

## `deployment.yaml` — le cœur

C'est la ressource qui dit à Kubernetes "fais tourner mon app". Les points importants :

**Réplicas + stratégie de rolling update :**

yaml

```yaml
replicas: 2
maxUnavailable: 0
minReadySeconds: 10
```

Pendant un déploiement, Kubernetes démarre le nouveau pod avant de tuer l'ancien. Il attend 10 secondes que le nouveau soit stable. Résultat : zéro downtime.

**Anti-affinity :**

yaml

```yaml
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    topologyKey: kubernetes.io/hostname
```

Kubernetes va _préférer_ placer les 2 pods sur des nodes différents. Si un node tombe, l'app reste up sur l'autre.

**initContainer :**

yaml

```yaml
until nc -z mysql-host 3306; do sleep 3; done
```

Un petit container `busybox` qui tourne _avant_ le container principal. Il fait une boucle TCP jusqu'à ce que MySQL réponde sur le port 3306. Sans ça, Laravel démarre, ne trouve pas MySQL, et crashe — Kubernetes redémarre en boucle avec des backoffs exponentiels.

**Variables d'environnement :**

- `envFrom: configMapRef` → injecte tout le ConfigMap comme variables d'env
- `env: secretKeyRef` → injecte `APP_KEY` et `DB_PASSWORD` depuis les Secrets

**Probes :**

- `readinessProbe` sur `/up` → Kubernetes n'envoie du trafic au pod que quand cette route répond 200. Pendant le démarrage de Laravel (composer autoload, cache, etc.), le pod est marqué "not ready" et exclu du load balancer.
- `livenessProbe` sur `/up` → si la route ne répond plus, Kubernetes redémarre le pod.

---

## `service.yaml` — le load balancer interne

Crée un DNS interne dans le cluster qui répartit le trafic entre les pods. Type `ClusterIP` = accessible uniquement depuis l'intérieur du cluster. L'Ingress s'en charge pour l'extérieur.

---

## `ingress.yaml` — l'exposition externe

Dit à nginx-ingress "quand tu reçois une requête pour `app.kubequest.local`, envoie-la au Service `myapp` sur le port 80". C'est le seul point d'entrée depuis l'extérieur.

---

## `hpa.yaml` — l'auto-scaling

Quand la consommation CPU moyenne des pods dépasse 70%, Kubernetes ajoute automatiquement des réplicas (jusqu'à 6 max). Quand la charge redescend, il en supprime (minimum 2).

---

## `pvc.yaml` + `cronjob-backup.yaml` — les backups

`pvc.yaml` crée un volume persistant de 2Gi pour stocker les backups.

`cronjob-backup.yaml` crée un job qui s'exécute tous les jours à 2h du matin. Il lance `mysqldump`, écrit le fichier sur le PVC avec un timestamp, et supprime les backups de plus de 7 jours. C'est l'équivalent Kubernetes d'un cron system classique.

---

## Le flux complet en une phrase

Helm injecte tes valeurs dans les templates → ça crée des Secrets, ConfigMaps, un Deployment, un Service, un Ingress, un HPA, un PVC et un CronJob → Kubernetes les applique → les 2 pods Laravel démarrent après que MySQL soit prêt → le trafic entre par l'Ingress, passe par le Service, et est load-balancé entre les pods.