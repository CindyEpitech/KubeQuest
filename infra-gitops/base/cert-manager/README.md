# cert-manager — TLS for *.kubequest.local (bonus)

Adds real, cert-manager-issued TLS certificates to the cluster's Ingress
routes. Because `*.kubequest.local` is a private domain that Let's Encrypt
cannot validate, we run a small **self-signed CA** inside the cluster and let
cert-manager mint per-host leaf certs from it.

## What's here

| File | Purpose |
|------|---------|
| `cluster-issuer.yaml` | The self-signed CA chain (bootstrap issuer → root CA → CA `ClusterIssuer` named `kubequest-ca`) |
| `kustomization.yaml` | Wires the above into the `infra` overlay |

The controller itself is **not** in GitOps (same as nginx-ingress / prometheus):
install it once with helm, then ArgoCD applies the issuer chain on top.

## Install cert-manager (once, out-of-band)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.7 \                 # see note 1
  --set installCRDs=true \
  --set webhook.hostNetwork=true \    # see note 2
  --set webhook.securePort=10260 \    # 10250 is the kubelet, so move it
  --wait
```

> **Note 1 — pin v1.14.x on this cluster.** It runs Kubernetes 1.29. cert-manager
> ≥1.15 ships CRDs that use `selectableFields`, which only exists on k8s ≥1.30, so
> the install fails with *"field not declared in schema"*. v1.14.7 is the right line.
>
> **Note 2 — the webhook must run hostNetwork here.** This cluster's API server
> can't reach pod-network pods (the same reason metrics-server and gatekeeper run
> `hostNetwork`). Without it the API server times out calling the validation
> webhook and every Issuer/Certificate apply fails with *"webhook ... context
> deadline exceeded"*.

After ArgoCD syncs the `infra` app (or `kubectl apply -k` this dir), check:

```bash
kubectl get clusterissuer kubequest-ca          # READY=True
kubectl -n cert-manager get secret kubequest-ca-tls
```

## Use it on an Ingress

Add the annotation + a `tls:` block; ingress-shim creates the Certificate and
the Secret automatically:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: kubequest-ca
spec:
  tls:
    - hosts: [app.kubequest.local]
      secretName: app-tls
```

The **app ingress** already does this via the Helm chart
(`ingress.tls.enabled`). It keeps `ssl-redirect: "false"` so plain HTTP and the
load-test / demo probers keep working alongside HTTPS.

## Trust the CA (removes browser warnings for the demo)

```bash
kubectl -n cert-manager get secret kubequest-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > kubequest-ca.crt
# import kubequest-ca.crt into the demo machine's browser / OS trust store
```

Then `https://app.kubequest.local` shows a valid padlock instead of a warning.

## Extending to Grafana / Prometheus / Dashboard (follow-up — do carefully)

Those ingresses sit behind oauth2-proxy with **`http://` auth-signin URLs**. To
TLS them you must also flip those annotations to `https://` (and review
`ssl-redirect` + cookie `secure` flags), or the login redirect breaks. Left out
of this first pass on purpose — the app route is the safe, self-contained demo.
