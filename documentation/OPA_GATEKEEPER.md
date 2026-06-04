# OPA Gatekeeper

## C'est quoi OPA ?

OPA signifie **Open Policy Agent**. C'est un moteur de règles qui permet de dire :

> "Cette action est autorisée seulement si elle respecte telle condition."

OPA n'est pas limité à Kubernetes. Il peut servir à contrôler des API, des pipelines CI/CD, des permissions cloud, etc. Dans Kubernetes, on l'utilise surtout pour valider les ressources avant qu'elles soient créées ou modifiées.

Exemple de règle :

- interdire les images Docker en `latest`
- obliger les containers à définir des limites CPU/mémoire
- interdire les pods privilégiés
- imposer certains labels

OPA lit la ressource demandée, évalue les règles, puis répond : autorisé ou refusé.

---

## C'est quoi Gatekeeper ?

**Gatekeeper** est l'intégration officielle d'OPA dans Kubernetes.

Kubernetes possède un mécanisme appelé **Admission Controller**. Quand quelqu'un fait :

```bash
kubectl apply -f deployment.yaml
```

la ressource ne va pas directement dans le cluster. Elle passe d'abord par plusieurs contrôles. Gatekeeper s'insère dans cette étape grâce à un **ValidatingWebhookConfiguration**.

Flux simplifié :

```text
kubectl apply
  -> kube-apiserver
  -> webhook Gatekeeper
  -> évaluation des policies OPA
  -> autorise ou refuse la ressource
```

Si la ressource respecte les règles, Kubernetes la crée. Sinon, l'API server renvoie une erreur `Forbidden`.

---

## Pourquoi on l'utilise dans KubeQuest ?

Dans KubeQuest, Gatekeeper sert à prouver que le cluster applique des règles de sécurité automatiquement.

L'objectif n'est pas seulement de documenter les bonnes pratiques. Le cluster les **enforce** vraiment : une ressource non conforme est bloquée avant même d'être créée.

Policies mises en place :

| Policy | But |
| --- | --- |
| `K8sRequiredResources` | Oblige chaque container à déclarer `resources.requests` et `resources.limits` pour CPU et mémoire |
| `K8sDisallowedLatestTag` | Interdit les images sans tag explicite ou avec le tag `latest` |

Ces policies protègent les namespaces :

- `default`
- `myapp`
- `myapp-dev`

On ne les applique pas à tous les namespaces du cluster, car certains composants tiers ne sont pas totalement contrôlés par nos manifests GitOps. Les bloquer pourrait empêcher des outils comme monitoring, ingress ou ArgoCD de fonctionner correctement.

---

## Les objets importants

### `ConstraintTemplate`

Le `ConstraintTemplate` définit un nouveau type de règle Kubernetes et contient le code Rego utilisé par OPA.

Dans le projet :

- `infra-gitops/base/gatekeeper/templates/required-resources.yaml`
- `infra-gitops/base/gatekeeper/templates/disallow-latest-tag.yaml`

Le langage utilisé dans ces fichiers s'appelle **Rego**. C'est le langage de policy d'OPA.

### `Constraint`

Le `Constraint` instancie une règle à partir d'un `ConstraintTemplate`.

Il dit :

- quelle règle appliquer
- sur quels types de ressources
- dans quels namespaces
- avec quelle action (`deny` dans notre cas)

Dans le projet :

- `infra-gitops/base/gatekeeper/constraints/require-resources.yaml`
- `infra-gitops/base/gatekeeper/constraints/disallow-latest-tag.yaml`

### `failurePolicy: Fail`

Le webhook Gatekeeper est configuré avec `failurePolicy: Fail`.

Cela signifie : si Kubernetes n'arrive pas à joindre Gatekeeper, la création de ressources est refusée par sécurité.

C'est plus strict que `Ignore`, mais c'est cohérent pour une démo de sécurité : on préfère bloquer une ressource plutôt que laisser passer une ressource non validée.

---

## Exemple de refus

Manifest invalide :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-latest-pod
  namespace: myapp
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

Gatekeeper refuse la création :

```text
admission webhook "validation.gatekeeper.sh" denied the request:
[disallow-latest-or-missing-image-tag] container <nginx> uses image <nginx:latest>;
images must use an explicit non-latest tag
```

Autre exemple : un container sans `resources.requests` ou `resources.limits` sera refusé par `K8sRequiredResources`.

---

## Comment tester dans KubeQuest

Après synchronisation de l'application ArgoCD `infra`, lancer :

```bash
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-no-resources-pod.yaml
```

Les deux commandes doivent échouer avec une erreur `Forbidden`.

Pour tester sans créer réellement la ressource :

```bash
kubectl apply --dry-run=server -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml
```

Commandes utiles :

```bash
kubectl get pods -n gatekeeper-system
kubectl get constrainttemplates
kubectl get k8srequiredresources
kubectl get k8sdisallowedlatesttag
kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration
```

---

## Particularité du cluster KubeQuest

Dans ce cluster, l'API server ne pouvait pas appeler correctement le webhook Gatekeeper via les IPs de pods Flannel (`10.244.x.x`).

Symptôme observé :

```text
failed calling webhook "validation.gatekeeper.sh": context deadline exceeded
```

Correction appliquée :

- Gatekeeper `controller-manager` tourne avec `hostNetwork: true`
- le namespace `gatekeeper-system` est autorisé en PodSecurity `privileged`
- le webhook Gatekeeper est exposé via les IPs des nodes au lieu des IPs de pods

Fichiers concernés :

- `infra-gitops/base/gatekeeper/patches/controller-manager-hostnetwork.yaml`
- `infra-gitops/base/gatekeeper/patches/namespace-podsecurity.yaml`
- `infra-gitops/base/gatekeeper/patches/validating-webhook-fail.yaml`

---

## Point d'attention : conflit avec nginx ingress

Gatekeeper en `hostNetwork` écoute sur le port `8443`. nginx ingress utilise aussi un hostPort `8443` pour son webhook d'admission.

Problème rencontré :

- Gatekeeper a été planifié sur le node `role=ingress`
- il a pris le port host `8443`
- le pod `ingress-nginx-controller` est resté `Pending`
- le front ne répondait plus, alors que les pods `myapp` étaient bien `Running`

Correction :

- Gatekeeper ne doit pas être planifié sur le node `role=ingress`
- le rollout Gatekeeper utilise `maxSurge: 0` pour éviter de démarrer un pod supplémentaire sur un port déjà pris
- une toleration permet à Gatekeeper d'utiliser le control-plane si nécessaire

Le but est de garder les deux garanties :

- Gatekeeper reste joignable par l'API server
- nginx ingress garde les ports nécessaires pour exposer le front

---

## Role dans la soutenance

OPA/Gatekeeper montre que le cluster ne repose pas uniquement sur de la discipline humaine.

Phrase simple à dire :

> "Gatekeeper est branché sur l'admission Kubernetes. Avant qu'une ressource soit créée, il vérifie nos policies OPA. Dans notre cluster, il bloque les images `latest` et les containers sans requests/limits dans les namespaces applicatifs."

Démo possible :

1. Montrer que `myapp` est `Synced/Healthy` dans ArgoCD.
2. Lancer un `kubectl apply --dry-run=server` sur `bad-latest-pod.yaml`.
3. Montrer l'erreur `Forbidden`.
4. Expliquer que la ressource est bloquée avant d'entrer dans le cluster.

---

## Résumé

OPA est le moteur de règles.

Gatekeeper est l'intégration Kubernetes d'OPA.

Dans KubeQuest, Gatekeeper sert à imposer automatiquement des règles de sécurité :

- pas d'image `latest`
- pas de container sans requests/limits
- enforcement uniquement sur les namespaces applicatifs
- intégration GitOps via ArgoCD

Cela transforme les bonnes pratiques Kubernetes en contrôles automatiques.
