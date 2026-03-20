# KubeQuest — Phase 5: Application GitOps
> Kustomize | CI/CD | Auto-deploy | Auto-rollback

---

## Overview

Deploy the application declaratively using a GitOps repository.
Every push to main triggers an automated build, deploy, health check, and rollback if something goes wrong.

---

## Repository Structure

```
app-gitops/
├── base/
│   ├── app/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   └── helmrelease.yaml
│   └── database/
│       ├── kustomization.yaml
│       └── helmrelease.yaml
└── overlays/
    └── production/
        ├── kustomization.yaml
        └── values-patch.yaml
```

---

## Base — App

```yaml
# base/app/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
  labels:
    app.kubernetes.io/managed-by: kustomize
```

```yaml
# base/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
```

---

## Overlays — Production

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: myapp

resources:
  - ../../base/app
  - ../../base/database

# Image tag override — updated by CI pipeline on every build
images:
  - name: your-registry/myapp
    newTag: "1.0.0"
```

---

## Deploy Manually

```bash
# Apply the full production overlay
kubectl apply -k overlays/production/

# Or via Helm (used in CI pipeline)
helm upgrade --install myapp ./charts/myapp \
  --namespace myapp \
  --create-namespace \
  --values overlays/production/values.yaml
```

---

## CI/CD Pipeline

### GitHub Actions

```yaml
# .github/workflows/deploy.yaml
name: Build and Deploy

on:
  push:
    branches:
      - main

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push:
    name: Build Docker Image
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.meta.outputs.version }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=,format=short

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}

  deploy:
    name: Deploy to Kubernetes
    runs-on: ubuntu-latest
    needs: build-and-push

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up kubectl
        uses: azure/setup-kubectl@v3

      - name: Configure kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBECONFIG }}" > ~/.kube/config

      - name: Install Helm
        uses: azure/setup-helm@v3

      - name: Deploy
        run: |
          helm upgrade --install myapp ./charts/myapp \
            --namespace myapp \
            --create-namespace \
            --set image.tag=${{ needs.build-and-push.outputs.image_tag }} \
            --set secret.dbPassword=${{ secrets.DB_PASSWORD }} \
            --set secret.appSecret=${{ secrets.APP_SECRET }} \
            --wait \
            --timeout 5m

      - name: Verify rollout
        run: |
          kubectl rollout status deployment/myapp -n myapp --timeout=5m

      - name: Rollback on failure
        if: failure()
        run: |
          echo "Deployment failed — rolling back..."
          kubectl rollout undo deployment/myapp -n myapp
          kubectl rollout status deployment/myapp -n myapp
          exit 1
```

---

### GitLab CI (alternative)

```yaml
# .gitlab-ci.yml
stages:
  - build
  - deploy

variables:
  IMAGE_TAG: $CI_COMMIT_SHORT_SHA

build:
  stage: build
  image: docker:24
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $CI_REGISTRY_IMAGE:$IMAGE_TAG .
    - docker push $CI_REGISTRY_IMAGE:$IMAGE_TAG

deploy:
  stage: deploy
  image: alpine/helm:3.13.0
  before_script:
    - mkdir -p ~/.kube
    - echo "$KUBECONFIG_CONTENT" > ~/.kube/config
    - apk add --no-cache kubectl
  script:
    - |
      helm upgrade --install myapp ./charts/myapp \
        --namespace myapp \
        --create-namespace \
        --set image.tag=$IMAGE_TAG \
        --set secret.dbPassword=$DB_PASSWORD \
        --wait \
        --timeout 5m
    - kubectl rollout status deployment/myapp -n myapp --timeout=5m
  after_script:
    - |
      if [ $CI_JOB_STATUS == 'failed' ]; then
        kubectl rollout undo deployment/myapp -n myapp
      fi
  only:
    - main
```

---

## Required Secrets (GitHub / GitLab)

| Secret | Value |
|--------|-------|
| `KUBECONFIG` | Base64-encoded kubeconfig file |
| `DB_PASSWORD` | Database password |
| `APP_SECRET` | Application secret key |

### Encode your kubeconfig
```bash
cat ~/.kube/config | base64 -w 0
# Paste the output as the KUBECONFIG secret
```

---

## Update Image Tag (Kustomize approach)

If using pure Kustomize (no Helm in CI), update the image tag automatically:

```bash
# In your CI pipeline, after building the image:
cd overlays/production/

# Update the image tag in kustomization.yaml
kustomize edit set image your-registry/myapp=your-registry/myapp:$IMAGE_TAG

# Commit and push the change
git add kustomization.yaml
git commit -m "ci: update image tag to $IMAGE_TAG"
git push
```

---

## Health Check Endpoint

Make sure your app exposes a `/health` endpoint:

```javascript
// Node.js example
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' })
})
```

```python
# Python/Flask example
@app.route('/health')
def health():
    return {'status': 'ok'}, 200
```

---

## Rollback Manually

```bash
# View rollout history
kubectl rollout history deployment/myapp -n myapp

# Rollback to previous version
kubectl rollout undo deployment/myapp -n myapp

# Rollback to a specific revision
kubectl rollout undo deployment/myapp -n myapp --to-revision=2
```

---

## Monitor Deployments

```bash
# Watch rollout in real time
kubectl rollout status deployment/myapp -n myapp

# Watch pods during deployment
kubectl get pods -n myapp -w

# Check recent events
kubectl get events -n myapp --sort-by='.lastTimestamp'
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pipeline fails at deploy | Check kubeconfig secret is valid and base64-encoded |
| `--wait` timeout | Increase timeout or check pod logs for crash reason |
| Rollback not triggering | Ensure `if: failure()` step is present in workflow |
| Image not found | Check registry credentials and image name |

---

## Next Step

Once automated deploys and rollbacks are working, proceed to:
**[Phase 6 — Security Layer](./PHASE_6_SECURITY.md)**