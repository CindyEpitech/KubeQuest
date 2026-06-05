#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest — broken deploy + automatic rollback demo
#
#  Shows the two safety nets baked into the app deployment, live:
#
#    1. Zero-downtime rolling update. The Deployment uses maxUnavailable=0 plus
#       a readiness probe, so a broken image never becomes Ready and the old
#       pods keep serving — the app stays up the whole time.
#
#    2. Automatic GitOps rollback. ArgoCD app `myapp-dev` runs with
#       selfHeal=true, so the moment we drift the live image away from what git
#       declares, ArgoCD reverts it back on its own. No human runs the rollback.
#
#  Flow:
#    - record the good image tag the deployment is currently running
#    - inject a bogus image tag with `kubectl set image` (-> ImagePullBackOff)
#    - prove the app still answers 200 (old pods still serving)
#    - nudge ArgoCD and watch it self-heal the image back to the git tag
#    - if selfHeal is disabled/slow, fall back to `kubectl rollout undo`
#
#  Usage:  ./break-deployment.sh [namespace] [argocd-app]
#            ./break-deployment.sh                  # myapp / myapp (prod, HA)
#            ./break-deployment.sh myapp-dev myapp-dev   # dev (single pod)
#
#  Defaults to prod (myapp): it runs 2-6 replicas, so the broken rollout has
#  live pods to keep serving — the cleanest zero-downtime story. Both apps have
#  ArgoCD selfHeal=true, so the automatic rollback works either way.
#
#  Assumes kubectl already points at the cluster (run ./deploy.sh once after a
#  reboot — it refreshes the kube-1 API-server IP).
# ─────────────────────────────────────────────────────────────────────────────

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${CYAN}${BOLD}==> $(date +%H:%M:%S)${NC}${CYAN} $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
fail() { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }

# ── Config ──────────────────────────────────────────────────────────────────
APP_NS="${1:-myapp}"
ARGO_APP="${2:-myapp}"
ARGO_NS="argocd"
DEPLOY="myapp-myapp"        # <release>-<chart>, same name in both namespaces
CONTAINER="myapp"           # container name inside the pod
REGISTRY="10.0.9.227:5000"  # broken tag reuses the real repo so only the tag is bad
BROKEN_IMAGE="$REGISTRY/myapp:broken-$(date +%s)"
HEAL_TIMEOUT=180            # seconds to wait for ArgoCD self-heal
[ "$APP_NS" = "myapp-dev" ] && APP_URL="http://app-dev.kubequest.local" || APP_URL="http://app.kubequest.local"

# ── Probe the app over HTTP; prints the status code, never aborts the script ──
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$APP_URL/" 2>/dev/null || echo "000"; }

# ═════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═════════════════════════════════════════════════════════════════════════════
step "[pre-flight] Checking cluster access..."
kubectl get ns "$APP_NS" >/dev/null 2>&1 || fail "Can't reach ns $APP_NS. Run ./deploy.sh first to refresh the API-server IP."
kubectl -n "$APP_NS" get deploy "$DEPLOY" >/dev/null 2>&1 || fail "Deployment $DEPLOY not found in ns $APP_NS."
ok "kubectl can reach $DEPLOY in ns $APP_NS"

GOOD_IMAGE=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}")
[ -z "$GOOD_IMAGE" ] && fail "Could not read current image for container $CONTAINER."
ok "Current (good) image: $GOOD_IMAGE"

# ═════════════════════════════════════════════════════════════════════════════
#  BEFORE
# ═════════════════════════════════════════════════════════════════════════════
step "[before] Healthy state:"
kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
echo
kubectl -n "$APP_NS" rollout history deploy "$DEPLOY" | tail -n 5
CODE=$(http_code)
[ "$CODE" = "200" ] && ok "App responds HTTP $CODE at $APP_URL" \
                     || warn "App returned HTTP $CODE (DNS/hosts not set on this machine?) — demo continues"

# ═════════════════════════════════════════════════════════════════════════════
#  BREAK — inject a bogus image tag
# ═════════════════════════════════════════════════════════════════════════════
step "[break] Setting a broken image: $BROKEN_IMAGE"
kubectl -n "$APP_NS" set image deploy/"$DEPLOY" "$CONTAINER=$BROKEN_IMAGE"
ok "Image drifted. New pods will fail to pull (ImagePullBackOff)."

step "[break] Watching the rollout fail (maxUnavailable=0 keeps old pods serving)..."
kubectl -n "$APP_NS" rollout status deploy/"$DEPLOY" --timeout=45s || true
echo
kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp

step "[break] Proving zero downtime — old pods still serve while the new ones are stuck:"
for i in 1 2 3 4 5; do
  CODE=$(http_code)
  [ "$CODE" = "200" ] && ok "request $i -> HTTP $CODE" || warn "request $i -> HTTP $CODE"
  sleep 1
done

# ═════════════════════════════════════════════════════════════════════════════
#  AUTOMATIC ROLLBACK — ArgoCD self-heal reverts the image back to the git tag
# ═════════════════════════════════════════════════════════════════════════════
step "[rollback] Nudging ArgoCD '$ARGO_APP' to reconcile (selfHeal will revert the drift)..."
kubectl -n "$ARGO_NS" annotate app "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
  || warn "Couldn't annotate ArgoCD app (is the argocd ns reachable?) — will fall back to rollout undo"

step "[rollback] Waiting for the live image to return to $GOOD_IMAGE (timeout ${HEAL_TIMEOUT}s)..."
deadline=$(( $(date +%s) + HEAL_TIMEOUT ))
HEALED=0
while :; do
  CUR=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}" 2>/dev/null || echo "")
  SYNC=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
  HEALTH=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")
  if [ "$CUR" = "$GOOD_IMAGE" ]; then HEALED=1; echo; ok "ArgoCD self-healed the image back to $GOOD_IMAGE"; break; fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo; break; }
  printf "    live-image=%s  sync=%s  health=%s\r" "${CUR##*:}" "$SYNC" "$HEALTH"
  sleep 5
done

# Fallback: selfHeal disabled or too slow -> roll back by hand the Kubernetes way.
if [ "$HEALED" -ne 1 ]; then
  warn "ArgoCD did not self-heal in ${HEAL_TIMEOUT}s — falling back to: kubectl rollout undo"
  kubectl -n "$APP_NS" rollout undo deploy/"$DEPLOY"
fi

step "[rollback] Waiting for the deployment to be healthy again..."
kubectl -n "$APP_NS" rollout status deploy/"$DEPLOY" --timeout=120s \
  || fail "Deployment did not become healthy after rollback — inspect: kubectl -n $APP_NS describe deploy $DEPLOY"

# ═════════════════════════════════════════════════════════════════════════════
#  AFTER
# ═════════════════════════════════════════════════════════════════════════════
step "[after] Recovered state:"
kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
CODE=$(http_code)
[ "$CODE" = "200" ] && ok "App responds HTTP $CODE at $APP_URL" || warn "App returned HTTP $CODE"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Broken deploy recovered                         ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Namespace:" "$APP_NS"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Rollback:"  "$([ "$HEALED" -eq 1 ] && echo 'ArgoCD self-heal' || echo 'kubectl rollout undo')"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Image:"     "${GOOD_IMAGE##*/}"
printf "${GREEN}${BOLD}║${NC}  %-10s  ${BOLD}%-35s${NC} ${GREEN}${BOLD}║${NC}\n" "Downtime:"  "none (maxUnavailable=0)"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
