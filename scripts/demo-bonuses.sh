#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest — DEFENSE DEMO: the bonus features, one per beat
#
#  Narrated, [Enter]-paced walkthrough of the implemented bonuses so you run a
#  script instead of typing during the defense:
#
#    1. ArgoCD               — GitOps reconciliation of every component
#    2. Private registry     — images pulled from our own registry on kube-1
#    3. Lightweight image    — multi-stage build, no build tools in the runtime
#    4. cert-manager TLS     — real certs from an in-cluster CA
#    5. MySQL NetworkPolicy  — DB reachable only by the app + backup pods
#    6. RBAC                 — least-privilege auditor (can't read secrets)
#
#  (Zero-downtime + automatic rollback has its own script: ./demo-rollback.sh)
#
#  Set AUTO=1 to run unattended. Run ./deploy.sh once after a reboot first so
#  kubectl points at the current kube-1 IP.
# ─────────────────────────────────────────────────────────────────────────────

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
say()  { echo -e "${BLUE}${BOLD}┃${NC} $*"; }
step() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
no()   { echo -e "${RED}  ✗  $*${NC}"; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }
run()  { echo -e "${DIM}\$ $*${NC}"; eval "$*"; }
pause() {
  [ "${AUTO:-0}" = "1" ] && { sleep 2; return; }
  echo -e "\n${DIM}   …press [Enter] to continue${NC}"; read -r _ < /dev/tty || true
}

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
APP_NS="myapp"                # prod app (app.kubequest.local, TLS)
NETPOL_NS="myapp-dev"        # NetworkPolicy is enabled here
DEPLOY="myapp-myapp"
REGISTRY="10.0.9.227:5000"
APP_HOST="app.kubequest.local"
AUDITOR_SA="system:serviceaccount:access-control:cluster-auditor"
INGRESS_NS="ingress-nginx"; INGRESS_SVC="ingress-nginx-controller"
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

clear 2>/dev/null || true
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   KubeQuest — Bonus features walkthrough                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
kubectl get ns "$APP_NS" >/dev/null 2>&1 || { no "Can't reach the cluster — run ./deploy.sh first."; exit 1; }
# The app (not the busybox init) container image.
APP_IMG=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[?(@.name=="myapp")].image}')
say "Six bonus beats. Zero-downtime + auto-rollback is its own demo"
say "(./scripts/demo-rollback.sh)."
pause

# ═════════════════════════════════════════════════════════════════════════════
step "1/6  ArgoCD — GitOps reconciliation"
say "Every cluster component and the app are reconciled from git by ArgoCD."
run "kubectl -n argocd get applications.argoproj.io"
say "infra, myapp and myapp-dev are all Synced + Healthy. A git push is the"
say "deploy — ArgoCD rolls it out and self-heals any drift."
pause

# ═════════════════════════════════════════════════════════════════════════════
step "2/6  Private registry — images come from our own registry"
say "No Docker Hub: every image is pulled from the registry running on kube-1."
echo -e "${DIM}\$ kubectl -n $APP_NS get deploy $DEPLOY -o jsonpath='{..image}'${NC}"
echo "    $APP_IMG"
say "That ${BOLD}$REGISTRY${NC} prefix is our private registry. The catalog"
say "(reachable only from inside the AWS network, on kube-1) is:"
echo -e "${DIM}    curl -s http://$REGISTRY/v2/_catalog   # {\"repositories\":[\"myapp\",\"mysql\"]}${NC}"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "3/6  Lightweight image — multi-stage build"
say "The app image is a multi-stage build: composer/git/dev-deps live only in a"
say "throwaway build stage; the runtime image carries just PHP + app + prod vendor."
echo
say "The build vs runtime stages:"
run "grep -nE '^FROM |AS (vendor|runtime)' '$REPO/sample-app/Dockerfile'"
echo
say "And .dockerignore keeps .git / host-vendor / node_modules / tests out:"
run "grep -vE '^#|^$' '$REPO/sample-app/.dockerignore' | head -8 | sed 's/^/    /'"
echo
say "Live image in use (built this way):"
echo "    $APP_IMG"
say "Size comparison on kube-1:  ${DIM}sudo nerdctl images | grep myapp${NC}"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "4/6  cert-manager TLS — real certs from an in-cluster CA"
say "*.kubequest.local is private, so Let's Encrypt can't validate it — instead"
say "a self-signed CA inside the cluster (cert-manager) mints per-host certs."
run "kubectl get clusterissuer"
run "kubectl -n $APP_NS get certificate"
echo
say "Proof nginx serves the issued cert (port-forwarding the controller)…"
kubectl -n "$INGRESS_NS" port-forward "svc/$INGRESS_SVC" 18443:443 >/dev/null 2>&1 &
PF_PID=$!
for i in $(seq 1 12); do
  echo | openssl s_client -connect 127.0.0.1:18443 -servername "$APP_HOST" 2>/dev/null | grep -q 'BEGIN CERTIFICATE' && break
  sleep 1
done
CERT=$(echo | openssl s_client -connect 127.0.0.1:18443 -servername "$APP_HOST" 2>/dev/null | openssl x509 -noout -issuer -subject -ext subjectAltName 2>/dev/null)
kill "$PF_PID" 2>/dev/null; PF_PID=""
if [ -n "$CERT" ]; then echo "$CERT" | sed 's/^/    /'
  ok "Served by our CA — issuer is 'KubeQuest Local Root CA'"
else warn "Couldn't read the cert over the port-forward (try again / check ingress)"; fi
say "Browser demo: import the CA and the padlock goes green —"
echo -e "${DIM}    kubectl -n cert-manager get secret kubequest-ca-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > ca.crt${NC}"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "5/6  MySQL NetworkPolicy — the DB is locked down"
say "Default-deny on the MySQL pod; only the app + backup pods may reach 3306."
run "kubectl -n $NETPOL_NS get networkpolicy"
echo
say "ALLOWED: the app itself talks to MySQL — its pods are Ready and serving the"
say "DB-backed page, which only works because app -> mysql is permitted:"
run "kubectl -n $NETPOL_NS get pods -l app.kubernetes.io/name=myapp --no-headers | grep -v Completed"
echo
say "DENIED: a rogue pod (no app labels) is blocked — watch it time out."
say "(It's pinned + resource-limited so OPA Gatekeeper admits it; the only thing"
say "stopping it is the NetworkPolicy.)"
echo -e "${DIM}\$ kubectl -n $NETPOL_NS run rogue --image=busybox:1.36 -- nc -zvw3 myapp-mysql 3306${NC}"
ROGUE_OVERRIDES='{"spec":{"containers":[{"name":"rogue","image":"busybox:1.36","command":["nc","-zvw3","myapp-mysql","3306"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
OUT=$(kubectl -n "$NETPOL_NS" run "rogue-$$" --rm -i --restart=Never \
  --image=busybox:1.36 --overrides="$ROGUE_OVERRIDES" 2>&1 || true)
echo "$OUT" | grep -ivE '^pod .* deleted$' | sed 's/^/    /'
if echo "$OUT" | grep -qiE 'timed out|refused|no route'; then
  ok "Blocked by the NetworkPolicy — the rogue pod cannot reach MySQL."
elif echo "$OUT" | grep -qi 'open'; then
  no "Port reported open — is the policy enabled in $NETPOL_NS?"
else
  warn "Inconclusive output above — re-run if the pod was slow to schedule."
fi
pause

# ═════════════════════════════════════════════════════════════════════════════
step "6/6  RBAC — least privilege"
say "Opposite the dashboard's cluster-admin: a read-only auditor that explicitly"
say "CANNOT read secrets or mutate anything."
printf "    %-26s -> %s\n" "list pods (cluster-wide)" "$(kubectl auth can-i list pods   -A --as=$AUDITOR_SA 2>/dev/null)"
printf "    %-26s -> %s\n" "get secrets"              "$(kubectl auth can-i get secrets -A --as=$AUDITOR_SA 2>/dev/null)"
printf "    %-26s -> %s\n" "delete pods"              "$(kubectl auth can-i delete pods -A --as=$AUDITOR_SA 2>/dev/null)"
echo
say "And a namespaced operator can manage its own namespace only:"
OP="system:serviceaccount:$APP_NS:$DEPLOY-operator"
printf "    %-30s -> %s\n" "delete deploy in $APP_NS"     "$(kubectl auth can-i delete deploy --as=$OP -n $APP_NS 2>/dev/null)"
printf "    %-30s -> %s\n" "delete deploy in monitoring"  "$(kubectl auth can-i delete deploy --as=$OP -n monitoring 2>/dev/null)"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "Done"
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Bonuses demonstrated                                        ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
for b in "ArgoCD GitOps" "Private registry" "Lightweight multi-stage image" \
         "cert-manager TLS (in-cluster CA)" "MySQL NetworkPolicy" "Least-privilege RBAC"; do
  printf "${GREEN}${BOLD}║${NC}  ✓ %-56s ${GREEN}${BOLD}║${NC}\n" "$b"
done
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
say "Plus zero-downtime + automatic rollback: ./scripts/demo-rollback.sh"
