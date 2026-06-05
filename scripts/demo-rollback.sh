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
PF_PORT=18080
# curl already prints "000" on failure via -w, so don't append our own fallback
# (that produced "000000"); just default to 000 if curl writes nothing at all.
http_code() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null); echo "${c:-000}"; }

# Decide what the prober hits. Prefer the real external ingress URL; if it isn't
# reachable from this machine (no /etc/hosts entry, ClusterIP-only ingress, WSL),
# fall back to a port-forward straight to the Service so the uptime counter still
# works. Sets PROBE_URL; returns non-zero if neither path answers.
setup_probe() {
  if [ "$(http_code "$APP_URL/")" = "200" ]; then
    PROBE_URL="$APP_URL/"; ok "Probing the real ingress URL: $APP_URL"; return 0
  fi
  warn "$APP_URL not reachable from here — port-forwarding svc/$DEPLOY instead"
  kubectl -n "$APP_NS" port-forward "svc/$DEPLOY" "$PF_PORT:80" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
  PROBE_URL="http://127.0.0.1:$PF_PORT/"
  if [ "$(http_code "$PROBE_URL")" = "200" ]; then
    ok "Probing via port-forward: 127.0.0.1:$PF_PORT -> svc/$DEPLOY:80"; return 0
  fi
  warn "Port-forward probe also failed — the uptime counter will have no data"; return 1
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
say "ArgoCD app '$ARGO_APP':  sync=${BOLD}$SYNC${NC}  health=${BOLD}$HEALTH${NC}"

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
say "Injecting a bogus image tag (same repo, tag does not exist):"
say "  ${BOLD}$BROKEN_IMAGE${NC}"
kubectl -n "$APP_NS" set image deploy/"$DEPLOY" "$CONTAINER=$BROKEN_IMAGE"
ok "Image drifted away from git. A new ReplicaSet is rolling out…"
echo
say "Watching the rollout — it will NOT complete (new pods can't pull):"
kubectl -n "$APP_NS" rollout status deploy/"$DEPLOY" --timeout=40s || true
echo
kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=myapp
echo
say "Notice: the new pod is ${RED}ImagePullBackOff${NC}, but the old pod is still"
say "${GREEN}Running${NC} — maxUnavailable=0 refuses to kill it until a replacement is Ready."
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
step "4/5  AUTOMATIC ROLLBACK — ArgoCD self-heals the drift"
say "We do NOT run a rollback command. ArgoCD sees the live image no longer"
say "matches git and reverts it on its own. (Nudging a refresh to speed it up.)"
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
