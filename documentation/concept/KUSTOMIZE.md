# Kustomize — Documentation KubeQuest

> **Projet** : KubeQuest  
> **Auteur** : Cindy  
> **Date** : Avril 2026  
> **Tags** : `kubernetes` `kustomize` `gitops` `deploy`

---

## Sommaire

1. [Pourquoi Kustomize ?](#1-pourquoi-kustomize-)
2. [Concepts clés](#2-concepts-clés)
3. [Structure de fichiers](#3-structure-de-fichiers)
4. [Le fichier kustomization.yaml](#4-le-fichier-kustomizationyaml)
5. [Les overlays](#5-les-overlays)
6. [Les types de patches](#6-les-types-de-patches)
7. [Features utiles](#7-features-utiles)
8. [Commandes essentielles](#8-commandes-essentielles)
9. [Intégration GitLab CI/CD](#9-intégration-gitlab-cicd)
10. [Kustomize vs Helm](#10-kustomize-vs-helm)
11. [Erreurs fréquentes](#11-erreurs-fréquentes)

---

## 1. Pourquoi Kustomize ?

Quand on déploie une application sur plusieurs environnements (dev, recette, prod), on est vite confronté à un problème :

**Les manifests Kubernetes sont presque identiques d'un env à l'autre**, mais avec quelques différences (namespace, nombre de replicas, tag d'image, ressources CPU/RAM…).

### Les mauvaises solutions

| Approche | Problème |
|---|---|
| Dupliquer les fichiers par env | Maintenance cauchemardesque, les fichiers divergent |
| Mettre des `{{ variables }}` dans le YAML | Le YAML n'est plus valide, besoin d'un moteur de template externe |
| Tout mettre dans un seul fichier | Illisible, pas de séparation des responsabilités |

### La solution Kustomize

Kustomize introduit une approche **base + overlay** :

- On écrit **une seule fois** les manifests de base
- Chaque environnement décrit **uniquement ses différences**
- Le YAML final est **généré à la volée** au moment du déploiement

> 💡 Kustomize est **intégré nativement dans `kubectl`** depuis la v1.14. Aucune installation supplémentaire requise.

---

## 2. Concepts clés

### Base

La **base** contient les manifests Kubernetes "neutres" — valides et déployables tels quels, sans aucune valeur spécifique à un environnement.

### Overlay

Un **overlay** pointe vers une base et décrit les modifications à y appliquer. Chaque environnement a son propre overlay.

### Patch

Un **patch** est une modification partielle d'un manifest. On ne réécrit pas tout le fichier, on indique seulement ce qui change.

### kustomization.yaml

Le **point d'entrée** de chaque couche (base ou overlay). C'est lui qui déclare les ressources à inclure et les transformations à appliquer.

---

## 3. Structure de fichiers

```
k8s/
├── base/
│   ├── kustomization.yaml       # déclare les ressources de base
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
│
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml   # surcharge pour dev
    │   └── patch-replicas.yaml
    ├── recette/
    │   ├── kustomization.yaml   # surcharge pour recette
    │   └── patch-resources.yaml
    └── prod/
        ├── kustomization.yaml   # surcharge pour prod
        └── patch-resources.yaml
```

> La base ne "sait" pas qu'elle a des overlays. Les overlays pointent vers la base, pas l'inverse.

---

## 4. Le fichier kustomization.yaml

### Dans la base

```yaml
# k8s/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - configmap.yaml
```

Il liste simplement les fichiers YAML à inclure.

### Dans un overlay

```yaml
# k8s/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base              # pointe vers la base

namespace: gpv2-dev-cms    # appliqué à toutes les ressources

namePrefix: dev-           # préfixe les noms (dev-mon-app, dev-mon-service…)

images:
  - name: mon-app
    newTag: latest          # surcharge le tag de l'image

replicas:
  - name: mon-app
    count: 1               # 1 replica en dev

patches:
  - path: patch-resources.yaml
```

---

## 5. Les overlays

### Exemple complet — overlay dev

```yaml
# k8s/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: gpv2-dev-cms
namePrefix: dev-

replicas:
  - name: mon-app
    count: 1

images:
  - name: mon-app
    newTag: latest

commonLabels:
  env: dev
  managed-by: kustomize
```

### Exemple complet — overlay prod

```yaml
# k8s/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

namespace: gpv2-prod

replicas:
  - name: mon-app
    count: 3

images:
  - name: mon-app
    newTag: v1.4.2          # tag fixe et versionné en prod

commonLabels:
  env: prod
  managed-by: kustomize

patches:
  - path: patch-resources.yaml
```

---

## 6. Les types de patches

Un patch est un fichier qui dit **"sur cette ressource, change ça"**. Il existe deux façons de l'écrire.

### Strategic Merge Patch

**L'idée** : tu réécris un morceau du manifest original, et Kustomize **fusionne** intelligemment avec la base.

Imagine que ta base a ça :

```yaml
# base/deployment.yaml
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: mon-app
          image: mon-app:latest
          ports:
            - containerPort: 8080
```

Tu veux juste ajouter des limites de ressources en prod. Ton patch :

```yaml
# k8s/overlays/prod/patch-resources.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mon-app              # ← identifie QUELLE ressource patcher
spec:
  template:
    spec:
      containers:
        - name: mon-app      # ← identifie QUEL container
          resources:         # ← ajoute/remplace uniquement ça
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
```

Le résultat fusionné : le container garde son `image`, ses `ports`, etc. — **seul `resources` est ajouté**. Kustomize est assez malin pour merger à la bonne profondeur dans l'arbre YAML.

> C'est la méthode à utiliser par défaut — intuitive, lisible, couvre 80% des cas.

### JSON Patch

**L'idée** : au lieu de réécrire un bloc YAML, tu décris une **liste d'opérations** à effectuer sur le document. Plus verbeux, mais plus précis.

Les opérations disponibles :

| Opération | Ce que ça fait |
|---|---|
| `replace` | Remplace la valeur d'un champ existant |
| `add` | Ajoute un champ ou un élément dans un tableau |
| `remove` | Supprime un champ |

```yaml
# k8s/overlays/prod/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: mon-app
    patch: |-
      - op: replace
        path: /spec/replicas        # chemin exact dans le YAML (notation slash)
        value: 3

      - op: add
        path: /spec/template/spec/containers/0/env/-   # "-" = ajoute à la fin du tableau
        value:
          name: ENV
          value: "production"

      - op: remove
        path: /spec/template/spec/containers/0/livenessProbe
```

Le `path` suit la **notation JSON Pointer** : chaque `/` descend d'un niveau dans l'arbre YAML. `containers/0` signifie "le premier container du tableau".

> À utiliser quand le merge patch ne suffit pas — notamment pour **supprimer** un champ existant dans la base, ce que le merge patch ne sait pas faire proprement.

### Résumé : lequel choisir ?

| Situation | Patch à utiliser |
|---|---|
| Ajouter ou modifier un bloc de config | **Strategic Merge Patch** |
| Changer une seule valeur précise | Les deux fonctionnent, merge est plus lisible |
| **Supprimer** un champ de la base | **JSON Patch** (`op: remove`) |
| Ajouter un élément dans un tableau | **JSON Patch** (`op: add` avec `/-`) |

---

## 7. Features utiles

### configMapGenerator

Génère un ConfigMap depuis des fichiers ou des valeurs littérales. Ajoute automatiquement un **hash** au nom, ce qui force un rollout à chaque changement de config.

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - ENV=dev
      - LOG_LEVEL=debug
    files:
      - config.properties
```

Résultat : `app-config-7t2g8k9h` (hash auto)

### secretGenerator

Même principe pour les Secrets :

```yaml
secretGenerator:
  - name: app-secret
    literals:
      - DB_PASSWORD=supersecret
```

> ⚠️ Ne pas committer de vraies valeurs en clair. En production, préférer des solutions comme External Secrets Operator ou Vault.

### commonAnnotations

```yaml
commonAnnotations:
  team: infra
  owner: cindy
  docs: "https://wiki.kubequest.internal/kustomize"
```

---

## 8. Commandes essentielles

```bash
# Visualiser le YAML final sans appliquer (dry-run indispensable)
kubectl kustomize overlays/dev/

# Appliquer directement
kubectl apply -k overlays/dev/

# Supprimer les ressources
kubectl delete -k overlays/dev/

# Avec kustomize standalone (version plus récente que celle embarquée dans kubectl)
kustomize build overlays/dev/ | kubectl apply -f -
kustomize build overlays/dev/ | kubectl apply --dry-run=client -f -
```

> 💡 Toujours faire un `kubectl kustomize overlays/XXX/` avant un apply pour vérifier le YAML généré.

---

## 9. Intégration GitLab CI/CD

Kustomize s'intègre naturellement dans une pipeline GitLab. On passe simplement le chemin de l'overlay selon la branche ou l'environnement cible.

```yaml
# .gitlab-ci.yml

variables:
  KUBECONFIG: /root/.kube/config

.deploy-template:
  image: bitnami/kubectl:latest
  script:
    - kubectl apply -k k8s/overlays/${OVERLAY}/

deploy:dev:
  extends: .deploy-template
  variables:
    OVERLAY: dev
  environment:
    name: dev
  only:
    - develop

deploy:prod:
  extends: .deploy-template
  variables:
    OVERLAY: prod
  environment:
    name: production
  only:
    - main
  when: manual
```

---

## 10. Kustomize vs Helm

| Critère | Kustomize | Helm |
|---|---|---|
| Approche | Patch/merge de YAML | Templating Go |
| Courbe d'apprentissage | Faible | Modérée à élevée |
| YAML toujours valide | ✅ Oui | ❌ Non (syntaxe `{{ }}`) |
| Intégré à kubectl | ✅ Oui | ❌ Non |
| Logique conditionnelle | Limitée | Puissante |
| Gestion des dépendances | ❌ Non | ✅ Oui (charts) |
| Réutilisabilité/distribution | Limitée | Très bonne |
| Idéal pour | Variantes d'un même app | Charts partagés/distribués |

**Règle simple :**
- Tu gères **tes propres apps** sur plusieurs envs → **Kustomize**
- Tu veux **packager et distribuer** une app pour que d'autres l'installent → **Helm**
- Les deux peuvent coexister (Helm pour les dépendances tierces, Kustomize pour tes apps maison)

---

## 11. Erreurs fréquentes

### Le namespace n'est pas appliqué

Vérifier que le champ `namespace` est bien dans le `kustomization.yaml` de l'overlay, pas dans les fichiers de la base.

### Le patch ne s'applique pas

Le `name` dans le patch doit correspondre **exactement** au `metadata.name` de la ressource dans la base (sans le `namePrefix` qui est ajouté après).

### `unknown field` à l'apply

Exécuter `kubectl kustomize overlays/xxx/` pour voir le YAML final généré et identifier l'incohérence avant d'appliquer.

### Les modifications de ConfigMap ne redémarrent pas les pods

Utiliser `configMapGenerator` au lieu d'un ConfigMap manuel — le hash auto dans le nom force le rollout automatiquement.

---

*Documentation interne KubeQuest — mise à jour : Avril 2026*