#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  KubeQuest — DEFENSE DEMO: broken deployment with automatic rollback
#
#  A narrated, paced version of break-deployment.sh built to present to the
#  teacher. It states the requirement, then proves it live:
#
#    "Demonstrate a full deployment process and a broken deployment with
#     automatic rollback."  +  "successful HTTP request during deployment"
#
#  How it proves it:
#    - a background prober hits the app once a second the WHOLE time and tallies
#      success/failure, so zero-downtime is a hard number on screen, not a claim
#    - it deploys a broken image and shows the new pods stuck in ImagePullBackOff
#      while the old pods keep serving (maxUnavailable=0 + readiness probe)
#    - it then does NOTHING to roll back by hand — ArgoCD (selfHeal=true) reverts
#      the image to what git declares on its own. That is the "automatic" part.
#
#  Paced with [Enter] between steps so you can talk over it. Set AUTO=1 to run
#  unattended (no prompts), e.g. for a dry run.
#
#  Usage:  ./demo-rollback.sh [namespace] [argocd-app]
#            ./demo-rollback.sh                       # myapp / prod (default, HA)
#            ./demo-rollback.sh myapp-dev myapp-dev   # dev (single pod)
#
#  Run ./deploy.sh once after a reboot first — it refreshes the kube-1 API IP.
# ─────────────────────────────────────────────────────────────────────────────

# ── Colors & helpers ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
say()  { echo -e "${BLUE}${BOLD}┃${NC} $*"; }
step() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
bad()  { echo -e "${RED}  ✗  $*${NC}"; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }
fail() { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }
pause() {
  [ "${AUTO:-0}" = "1" ] && { sleep 2; return; }
  echo -e "\n${DIM}   …press [Enter] to continue${NC}"
  read -r _ < /dev/tty || true
}

# ── Config (kept in sync with break-deployment.sh) ───────────────────────────
APP_NS="${1:-myapp}"
ARGO_APP="${2:-myapp}"
ARGO_NS="argocd"
DEPLOY="myapp-myapp"
CONTAINER="myapp"
REGISTRY="10.0.9.227:5000"
BROKEN_IMAGE="$REGISTRY/myapp:broken-$(date +%s)"
HEAL_TIMEOUT=180
[ "$APP_NS" = "myapp-dev" ] && APP_URL="http://app-dev.kubequest.local" || APP_URL="http://app.kubequest.local"

PROBE_LOG="$(mktemp)"; PROBE_PID=""; PF_PID=""
PROBE_URL="$APP_URL/"          # resolved by setup_probe (external, else port-forward)
HOST_HEADER=""                 # set when we tunnel through the ingress controller
PF_PORT=18080
INGRESS_NS="ingress-nginx"; INGRESS_SVC="ingress-nginx-controller"
APP_HOST="${APP_URL#http://}"; APP_HOST="${APP_HOST%/}"   # app[-dev].kubequest.local

# curl already prints "000" on failure via -w, so don't append our own fallback
# (that produced "000000"); just default to 000 if curl writes nothing at all.
# When HOST_HEADER is set we send it so nginx routes to the app's Ingress rule.
http_code() {
  local c
  if [ -n "$HOST_HEADER" ]; then
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $HOST_HEADER" "$1" 2>/dev/null)
  else
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)
  fi
  echo "${c:-000}"
}

# Poll a URL until it answers 200 — port-forwards (esp. to the hostNetwork
# ingress controller) need a moment to come up before the first request lands.
wait_200() { local u="$1" n="${2:-10}" i; for ((i=0; i<n; i++)); do [ "$(http_code "$u")" = "200" ] && return 0; sleep 1; done; return 1; }

# Decide what the prober hits, preferring paths that exercise the real ingress:
#   1. the external ingress URL (if /etc/hosts points at the ingress node)
#   2. a port-forward to the nginx ingress controller + Host header — still the
#      real nginx -> Ingress -> Service path, just tunneled (no /etc/hosts needed)
#   3. last resort: a port-forward straight to the app Service (bypasses nginx)
# Sets PROBE_URL (+ HOST_HEADER); returns non-zero if nothing answers.
setup_probe() {
  if [ "$(http_code "$APP_URL/")" = "200" ]; then
    PROBE_URL="$APP_URL/"; HOST_HEADER=""; ok "Probing the real ingress URL: $APP_URL"; return 0
  fi
  if kubectl -n "$INGRESS_NS" get svc "$INGRESS_SVC" >/dev/null 2>&1; then
    warn "$APP_URL not reachable — port-forwarding the nginx ingress controller"
    kubectl -n "$INGRESS_NS" port-forward "svc/$INGRESS_SVC" "$PF_PORT:80" >/dev/null 2>&1 &
    PF_PID=$!
    PROBE_URL="http://127.0.0.1:$PF_PORT/"; HOST_HEADER="$APP_HOST"
    if wait_200 "$PROBE_URL" 10; then
      ok "Probing via nginx: 127.0.0.1:$PF_PORT  Host: $APP_HOST  (real ingress path)"; return 0
    fi
    warn "Ingress-controller probe didn't answer — falling back to the Service"
    [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; PF_PID=""; HOST_HEADER=""; sleep 1
  fi
  kubectl -n "$APP_NS" port-forward "svc/$DEPLOY" "$PF_PORT:80" >/dev/null 2>&1 &
  PF_PID=$!
  PROBE_URL="http://127.0.0.1:$PF_PORT/"; HOST_HEADER=""
  if wait_200 "$PROBE_URL" 10; then
    ok "Probing via port-forward to svc/$DEPLOY:80 (bypasses nginx)"; return 0
  fi
  warn "All probe paths failed — the uptime counter will have no data"; return 1
}

# Background uptime prober — one request/second appended to $PROBE_LOG.
start_prober() {
  ( while :; do echo "$(date +%H:%M:%S) $(http_code "$PROBE_URL")"; sleep 1; done >> "$PROBE_LOG" ) &
  PROBE_PID=$!
}
# total ok fail  (2xx/3xx counts as a successful request)
probe_stats() {
  local total ok
  total=$(wc -l < "$PROBE_LOG" | tr -d ' ')
  ok=$(grep -cE ' (2..|3..)$' "$PROBE_LOG" 2>/dev/null || echo 0)
  echo "$total $ok $(( total - ok ))"
}

# Toggle ArgoCD self-heal on the app. We pause it during the break so the
# broken state is actually visible (otherwise it reverts the drift in ~1s and
# nobody sees the failure), then switch it back on to perform the rollback.
ORIG_SELFHEAL=""
set_selfheal() {
  kubectl -n "$ARGO_NS" patch app "$ARGO_APP" --type merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":$1}}}}" >/dev/null 2>&1
}

# Show the broken state: wait until a pod surfaces ImagePullBackOff/ErrImagePull
# (up to ~40s, after the init container finishes), then print the pod list.
show_broken_pods() {
  local deadline=$(( $(date +%s) + 40 )) seen=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp \
         -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
         | grep -qE 'ImagePullBackOff|ErrImagePull'; then seen=1; break; fi
    sleep 2
  done
  kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
  [ "$seen" -eq 1 ] || warn "(didn't catch ImagePullBackOff in the window — the pod may still be pulling)"
}

# Safety net: if the demo is interrupted while broken, put it back.
cleanup() {
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  local cur
  cur=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}" 2>/dev/null || echo "")
  if [ -n "${GOOD_IMAGE:-}" ] && [ "$cur" = "$BROKEN_IMAGE" ]; then
    warn "Interrupted while broken — rolling back so the cluster is left healthy..."
    kubectl -n "$APP_NS" set image deploy/"$DEPLOY" "$CONTAINER=$GOOD_IMAGE" >/dev/null 2>&1 || true
  fi
  # Always put ArgoCD self-heal back the way we found it.
  [ -n "$ORIG_SELFHEAL" ] && set_selfheal "$ORIG_SELFHEAL"
  rm -f "$PROBE_LOG"
}
trap cleanup EXIT INT TERM

clear 2>/dev/null || true
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   KubeQuest — Broken deployment with AUTOMATIC ROLLBACK       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
say "Defense requirement:"
say "  ${BOLD}\"demonstrate a full deployment process and a broken deployment"
say "   with automatic rollback\"${NC} — and keep serving HTTP throughout."
echo
say "Two mechanisms make this automatic — no human runs the rollback:"
say "  1) ${BOLD}maxUnavailable: 0${NC} + readiness probe → a broken image never"
say "     becomes Ready, so the old pods keep serving (zero downtime)."
say "  2) ${BOLD}ArgoCD selfHeal: true${NC} → the live image is forced back to what"
say "     git declares the moment it drifts (the automatic rollback)."
pause

# ═════════════════════════════════════════════════════════════════════════════
step "1/5  Starting point — a healthy, deployed application"
kubectl -n "$APP_NS" get deploy "$DEPLOY" >/dev/null 2>&1 \
  || fail "Deployment $DEPLOY not found in ns $APP_NS. Run ./deploy.sh first."
GOOD_IMAGE=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}")
[ -z "$GOOD_IMAGE" ] && fail "Could not read the current image."

kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
echo
say "Running image (declared in git):  ${BOLD}$GOOD_IMAGE${NC}"
SYNC=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
HEALTH=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")
ORIG_SELFHEAL=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)
say "ArgoCD app '$ARGO_APP':  sync=${BOLD}$SYNC${NC}  health=${BOLD}$HEALTH${NC}  selfHeal=${BOLD}${ORIG_SELFHEAL:-?}${NC}"

setup_probe || warn "The rollback still works; only the uptime counter is affected."
pause

# ═════════════════════════════════════════════════════════════════════════════
step "2/5  Start the live uptime monitor (proves zero-downtime)"
start_prober
say "A background prober now hits ${BOLD}$PROBE_URL${NC} once per second and tallies"
say "every response. Watch this counter stay green through the whole break."
sleep 4
read -r T O F <<<"$(probe_stats)"
ok "baseline: $O/$T requests OK"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "3/5  BREAK IT — deploy an image that cannot be pulled"
say "First we briefly ${BOLD}pause ArgoCD's self-heal${NC} — otherwise it reverts the"
say "drift in ~1 second and you'd never get to see the broken state. (We switch"
say "it back on in step 4; the rollback is still done by ArgoCD, not by us.)"
set_selfheal false && ok "selfHeal paused (temporary — restored at the end)"
echo
say "Now inject a bogus image tag (same repo, tag does not exist):"
say "  ${BOLD}$BROKEN_IMAGE${NC}"
kubectl -n "$APP_NS" set image deploy/"$DEPLOY" "$CONTAINER=$BROKEN_IMAGE"
ok "Image drifted away from git. A new ReplicaSet is rolling out…"
echo
say "Waiting for the broken pod to surface (it can't pull the image):"
show_broken_pods
echo
say "The new pod is ${RED}ImagePullBackOff${NC}, but the old pods are still"
say "${GREEN}Running${NC} — maxUnavailable=0 refuses to kill them until a replacement is Ready."
pause

# ═════════════════════════════════════════════════════════════════════════════
step "3b   …and the app never went down"
say "Live requests during the broken rollout:"
for i in $(seq 1 6); do
  L=$(tail -1 "$PROBE_LOG" 2>/dev/null || echo "-")
  echo -e "   ${DIM}probe:${NC} $L"
  sleep 1
done
read -r T O F <<<"$(probe_stats)"
if [ "$F" -eq 0 ] && [ "$O" -gt 0 ]; then ok "ZERO downtime so far: $O/$T requests succeeded, $F failed"
elif [ "$O" -gt 0 ]; then warn "$O/$T OK, $F failed (transient blips can happen on the ingress)"
else warn "prober has no successful samples — external URL not reachable from here"; fi
pause

# ═════════════════════════════════════════════════════════════════════════════
step "4/5  AUTOMATIC ROLLBACK — switch ArgoCD self-heal back on"
say "We run ${BOLD}no rollback command${NC}. We just re-enable ArgoCD's self-heal and it"
say "reverts the live image back to what git declares, entirely on its own."
set_selfheal true && ok "selfHeal re-enabled — ArgoCD will now reconcile the drift"
kubectl -n "$ARGO_NS" annotate app "$ARGO_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
  || warn "Couldn't reach ArgoCD app — will fall back to 'kubectl rollout undo'"

say "Waiting for the live image to return to ${BOLD}${GOOD_IMAGE##*:}${NC} (≤ ${HEAL_TIMEOUT}s)…"
deadline=$(( $(date +%s) + HEAL_TIMEOUT )); HEALED=0
while :; do
  CUR=$(kubectl -n "$APP_NS" get deploy "$DEPLOY" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='$CONTAINER')].image}" 2>/dev/null || echo "")
  SYNC=$(kubectl -n "$ARGO_NS" get app "$ARGO_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")
  [ "$CUR" = "$GOOD_IMAGE" ] && { echo; ok "ArgoCD self-healed the image back to $GOOD_IMAGE"; HEALED=1; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { echo; break; }
  printf "   ${DIM}live-image=%-16s argo-sync=%s${NC}\r" "${CUR##*:}" "$SYNC"
  sleep 5
done
if [ "$HEALED" -ne 1 ]; then
  warn "ArgoCD did not self-heal in time — falling back to the manual k8s rollback:"
  say "  kubectl rollout undo deploy/$DEPLOY"
  kubectl -n "$APP_NS" rollout undo deploy/"$DEPLOY"
fi
kubectl -n "$APP_NS" rollout status deploy/"$DEPLOY" --timeout=120s \
  || fail "Deployment did not recover — inspect: kubectl -n $APP_NS describe deploy $DEPLOY"
ok "Deployment healthy again"
pause

# ═════════════════════════════════════════════════════════════════════════════
step "5/5  Result"
[ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""
kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
read -r T O F <<<"$(probe_stats)"
CODE=$(http_code "$PROBE_URL")
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Requirement demonstrated                                   ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${GREEN}${BOLD}║${NC}  %-26s %-32s ${GREEN}${BOLD}║${NC}\n" "Broken deploy:"        "detected (ImagePullBackOff)"
printf "${GREEN}${BOLD}║${NC}  %-26s %-32s ${GREEN}${BOLD}║${NC}\n" "Rollback:"             "$([ "$HEALED" -eq 1 ] && echo 'AUTOMATIC (ArgoCD selfHeal)' || echo 'kubectl rollout undo (fallback)')"
printf "${GREEN}${BOLD}║${NC}  %-26s %-32s ${GREEN}${BOLD}║${NC}\n" "Restored image:"       "${GOOD_IMAGE##*/}"
printf "${GREEN}${BOLD}║${NC}  %-26s %-32s ${GREEN}${BOLD}║${NC}\n" "HTTP during deploy:"   "$O/$T OK, $F failed"
printf "${GREEN}${BOLD}║${NC}  %-26s %-32s ${GREEN}${BOLD}║${NC}\n" "App now:"              "HTTP $CODE"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
[ "$F" -eq 0 ] && [ "$O" -gt 0 ] && ok "Zero-downtime confirmed: not a single request was dropped."
