# Gatekeeper policies

This base installs OPA Gatekeeper and enforces two admission policies:

- containers must define CPU and memory requests and limits;
- images must use an explicit tag that is not `latest`.

The policy constraints exclude `kube-system`, `gatekeeper-system`, and `argocd`
to avoid blocking cluster controllers during bootstrap.

The `ConstraintTemplate` and `Constraint` objects use ArgoCD sync waves because
Gatekeeper creates the custom constraint CRDs from the templates.

Test after ArgoCD syncs the infra app:

```bash
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-no-resources-pod.yaml
```

Both commands should be denied by Gatekeeper.
