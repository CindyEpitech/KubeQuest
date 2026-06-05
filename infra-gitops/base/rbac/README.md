# RBAC — orchestrator access permissions (bonus)

The cluster ships two identities at opposite ends of the privilege spectrum,
plus one defined per app namespace:

| Identity | Scope | Can | Cannot |
|----------|-------|-----|--------|
| `admin-user` (kubernetes-dashboard) | cluster-admin | everything | — |
| `cluster-auditor` (access-control) | cluster-wide **read-only** | get/list/watch most resources, `kubectl top` | read **secrets**, mutate anything |
| `<release>-operator` (app namespace) | **one namespace** | manage the app's workloads | touch other namespaces or cluster resources |

The auditor + operator demonstrate **least privilege**: hand someone exactly the
access they need, nothing more.

## Try the auditor

```bash
# Mint a short-lived token for the read-only auditor:
TOKEN=$(kubectl -n access-control create token cluster-auditor)

# Allowed — read-only inspection works cluster-wide:
kubectl --token="$TOKEN" get pods -A
kubectl --token="$TOKEN" get nodes

# Denied — it cannot read secrets or change anything:
kubectl --token="$TOKEN" get secret -n myapp            # Forbidden
kubectl --token="$TOKEN" delete pod -n myapp --all      # Forbidden
```

Or check with `kubectl auth can-i`:

```bash
kubectl auth can-i list pods   -A --as=system:serviceaccount:access-control:cluster-auditor   # yes
kubectl auth can-i get secrets -A --as=system:serviceaccount:access-control:cluster-auditor   # no
kubectl auth can-i delete pods -A --as=system:serviceaccount:access-control:cluster-auditor   # no
```

## The per-namespace operator

Defined by the app Helm chart (`templates/rbac.yaml`, `rbac.create`). It's a
namespaced Role + RoleBinding, so the same SA can manage `myapp` resources but
is powerless everywhere else:

```bash
SA=system:serviceaccount:myapp:myapp-myapp-operator
kubectl auth can-i delete deploy --as=$SA -n myapp        # yes
kubectl auth can-i delete deploy --as=$SA -n monitoring   # no
kubectl auth can-i get secrets  --as=$SA -n myapp         # yes (read only)
kubectl auth can-i delete secrets --as=$SA -n myapp       # no
```
