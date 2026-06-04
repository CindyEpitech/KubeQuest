# Gatekeeper policies

This base installs OPA Gatekeeper and enforces two admission policies:

- containers must define CPU and memory requests and limits;
- images must use an explicit tag that is not `latest`.

The policy constraints apply only to `default`, `myapp`, and `myapp-dev`.
That keeps the demo/application workloads protected without blocking third-party
controllers that do not expose resource settings in our GitOps repo.

The `ConstraintTemplate` and `Constraint` objects use ArgoCD sync waves because
Gatekeeper creates the custom constraint CRDs from the templates.

In this cluster, the API server cannot reliably call Flannel pod IPs for
admission webhooks. The Gatekeeper controller-manager therefore runs with
`hostNetwork: true`, and only the `gatekeeper-system` namespace is relaxed to
PodSecurity `privileged`.

Test after ArgoCD syncs the infra app:

```bash
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-latest-pod.yaml
kubectl apply -f infra-gitops/base/gatekeeper/tests/bad-no-resources-pod.yaml
```

Both commands should be denied by Gatekeeper.
