## C'est quoi ArgoCD ?

ArgoCD c'est un outil de **GitOps** pour Kubernetes. L'idée : ton dépôt Git devient la **source de vérité** de ce qui tourne dans le cluster. Tu ne fais plus `kubectl apply` ou `helm install` à la main — tu pousses tes changements sur Git, et ArgoCD se charge de les appliquer dans le cluster automatiquement.

En gros, ArgoCD tourne en permanence et compare deux choses :

- **l'état désiré** → ce qui est décrit dans ton dépôt Git (manifests, charts Helm, etc.)
- **l'état réel** → ce qui tourne vraiment dans le cluster

Si les deux divergent, ArgoCD le signale (`OutOfSync`) et peut corriger tout seul.

---

## Pourquoi c'est utile ?

Sans GitOps, l'état du cluster vit dans la tête des gens et dans des commandes lancées à la main. Personne ne sait exactement ce qui est déployé ni qui a changé quoi.

Avec ArgoCD :

- **Tout est tracé** → chaque changement passe par un commit Git. L'historique Git = l'historique des déploiements.
- **Reproductible** → si le cluster crashe, tu réappliques le dépôt et tu retrouves le même état.
- **Rollback facile** → tu reviens à un commit précédent, ArgoCD resync.
- **Plus de drift manuel** → si quelqu'un bidouille le cluster à la main, ArgoCD le détecte (et peut le corriger).

---

## Le concept central : l'`Application`

Dans ArgoCD, tu déclares une ressource **`Application`**. C'est elle qui fait le lien entre un bout de ton dépôt Git et un endroit dans le cluster. Une Application dit en gros :

> « Prends ce chart Helm dans ce dépôt, sur cette branche, et déploie-le dans ce namespace. »

Les champs importants :

```yaml
source:
  repoURL: <le dépôt Git>
  targetRevision: main      # la branche ou le tag à suivre
  path: helm/myapp          # où sont les manifests/le chart
destination:
  namespace: myapp          # où déployer dans le cluster
```

Dans KubeQuest, les Applications committées sont dans `infra-gitops/argocd/applications/`.

ℹ️ **Note KubeQuest :** il y a eu un temps une divergence — les Applications vivantes pointaient vers `develop` (pour tester la synchro) alors que les manifests committés pointaient vers `main`. C'est désormais **réconcilié** (2026-05-29) : `develop` a été mergé dans `main`, et les apps ont été repointées sur les manifests committés. État actuel : `infra` et `myapp` suivent `main`, `myapp-dev` suit `develop` (c'est l'environnement de dev, par design). Détails dans [`ARGOCD_NOTES.md`](../ARGOCD_NOTES.md).

---

## Sync : appliquer l'état désiré

Quand l'état Git et l'état cluster divergent, ArgoCD fait un **sync** : il applique ce qui est dans Git pour que le cluster corresponde.

Deux modes :

- **Manuel** → tu cliques sur "Sync" (ou `argocd app sync`) quand tu veux.
- **Automatique** (`automated`) → dès qu'un commit arrive sur la branche suivie, ArgoCD applique tout seul, sans intervention.

Dans KubeQuest, l'auto-sync est activé : un `git push` d'un changement de values a été appliqué en live en ~114 secondes, sans aucune commande manuelle.

---

## `selfHeal` : corriger le drift manuel

Avec `selfHeal: true`, si quelqu'un modifie une ressource directement dans le cluster (un `kubectl edit` à la main), ArgoCD **revient à la valeur de Git**. Le cluster ne peut plus dériver de la source de vérité.

Testé dans KubeQuest : on a modifié manuellement le `maxReplicas` du HPA → ArgoCD l'a remis à la valeur du dépôt.

---

## `ignoreDifferences` : les exceptions au selfHeal

Parfois, une partie d'une ressource est censée changer toute seule, et tu **ne veux pas** que selfHeal la combatte. Le cas classique : le nombre de réplicas géré par le HorizontalPodAutoscaler.

Si le HPA scale à 5 pods, mais que Git dit `replicas: 2`, selfHeal voudrait revenir à 2 → guerre sans fin entre ArgoCD et le HPA.

La solution : `ignoreDifferences` sur `/spec/replicas` du Deployment. ArgoCD ignore ce champ et laisse le HPA faire son travail.

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

---

## Resource tracking : comment ArgoCD reconnaît ses ressources

ArgoCD doit savoir quelles ressources du cluster lui appartiennent. Par défaut, il utilise un **label** (`app.kubernetes.io/instance`).

⚠️ **Gros piège dans KubeQuest :** le chart Helm `myapp` met déjà ce label sur ses objets. Du coup, avec le tracking par label, ArgoCD a "adopté" les Secrets pré-créés (`myapp-secret`, `myapp-db-secret`) puis les a **supprimés** (pruned) — et les pods ont planté avec `secret "myapp-secret" not found`.

**Le fix (committé) :** passer en tracking par **annotation** dans `argocd-cm` :

```yaml
application.resourceTrackingMethod: annotation
```

L'annotation est plus précise que le label : elle identifie sans ambiguïté ce qui a réellement été déployé par ArgoCD. À garder activé.

---

## Le flux complet en une phrase

Tu pousses un changement sur Git → ArgoCD détecte que l'état désiré (Git) diverge de l'état réel (cluster) → il fait un sync automatique pour appliquer le chart Helm dans le bon namespace → selfHeal garde le cluster aligné sur Git (sauf les champs ignorés comme les réplicas du HPA) → ton dépôt Git reste la seule source de vérité de ce qui tourne.
