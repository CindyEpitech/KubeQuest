#!/bin/bash
# load-test.sh — Hammer /cpu to trigger HPA scaling
#
# Usage:
#   ./load-test.sh [URL] [duration_seconds] [concurrency]
#
# Modes (set MODE=...):
#   in-cluster (default) — launches a `hey` pod INSIDE the cluster that hits the
#                          myapp Service directly. Works against a ClusterIP-only
#                          ingress on a remote cluster with no tunnel/DNS setup.
#   direct               — drives load from this host against URL. Needs the app
#                          reachable locally (e.g. via `kubectl port-forward`).
#
# Env overrides:
#   MODE        in-cluster | direct           (default: in-cluster)
#   SVC_TARGET  in-cluster Service host:port   (default: myapp-myapp.myapp)
#   HEY_IMAGE   image used for the loadgen pod (default: williamyeh/hey)
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $(date +%H:%M:%S) $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }

APP_URL="${1:-http://app.kubequest.local}"
DURATION="${2:-120}"
CONCURRENCY="${3:-30}"

MODE="${MODE:-in-cluster}"
SVC_TARGET="${SVC_TARGET:-myapp-myapp.myapp}"
HEY_IMAGE="${HEY_IMAGE:-williamyeh/hey}"

if [ "$MODE" = "in-cluster" ]; then
  CPU_URL="http://${SVC_TARGET}/cpu"
else
  CPU_URL="${APP_URL%/}/cpu"
fi

step "Pre-flight"
if ! kubectl get hpa -n myapp &>/dev/null; then
  warn "Cannot reach cluster — is kubectl configured?"
  exit 1
fi
ok "Mode:        $MODE"
ok "Target:      $CPU_URL"
ok "Duration:    ${DURATION}s"
ok "Concurrency: $CONCURRENCY workers"

step "HPA state before load"
kubectl get hpa -n myapp
echo ""
kubectl get pods -n myapp --no-headers | grep -v mysql | grep -v backup || true

step "Reachability check"
# A load run against an unreachable target generates ZERO load and looks exactly
# like "the HPA refused to scale". Confirm /cpu answers 2xx/3xx before loading.
if [ "$MODE" = "in-cluster" ]; then
  rc=0
  PRECHECK=$(kubectl run "loadtest-precheck-$$" -n myapp --rm -i --restart=Never \
    --image=curlimages/curl --command -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$CPU_URL" 2>/dev/null) || rc=$?
  HTTP_CODE=$(printf '%s' "$PRECHECK" | grep -oE '[0-9]{3}' | tail -1 || true)
  if [ "$rc" -ne 0 ] || [ -z "$HTTP_CODE" ]; then
    warn "Could not reach $CPU_URL from inside the cluster."
    warn "Check the Service name (SVC_TARGET) and that the pods are Ready."
    exit 1
  fi
else
  HOST_ONLY=$(printf '%s' "$APP_URL" | sed -E 's#^https?://##; s#[:/].*$##')
  rc=0
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$CPU_URL") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      6)  warn "Cannot resolve host '$HOST_ONLY' (DNS)." ;;
      7)  warn "Connection refused / no route to $CPU_URL." ;;
      28) warn "Timed out connecting to $CPU_URL." ;;
      *)  warn "curl failed (exit $rc) for $CPU_URL." ;;
    esac
    echo ""
    warn "The app is behind a ClusterIP-only ingress on a remote cluster — it is"
    warn "not reachable directly from this host. Either run the default in-cluster"
    warn "mode (just omit the URL arg), or open a tunnel in another terminal:"
    echo "      kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
    echo "      MODE=direct $0 http://$HOST_ONLY:8080 $DURATION $CONCURRENCY"
    exit 1
  fi
fi
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 400 ]; then
  warn "Reached $CPU_URL but got HTTP $HTTP_CODE (expected 2xx/3xx). Aborting before load."
  exit 1
fi
ok "Reachable — HTTP $HTTP_CODE"

step "Launching watchers (Ctrl+C to stop)"
# Open two background watches and store PIDs
kubectl get hpa -n myapp -w 2>/dev/null &
HPA_PID=$!
kubectl get pods -n myapp -w 2>/dev/null &
POD_PID=$!

LOADGEN="loadgen-$$"
cleanup() {
  kill "$HPA_PID" "$POD_PID" 2>/dev/null || true
  # If the run was interrupted, --rm may not have fired — clean up the pod.
  [ "$MODE" = "in-cluster" ] && kubectl delete pod "$LOADGEN" -n myapp --ignore-not-found --wait=false &>/dev/null || true
  echo ""
  step "Final HPA state"
  kubectl get hpa -n myapp
  echo ""
  step "Final pod count"
  kubectl get pods -n myapp --no-headers | grep -v mysql | grep -v backup || true
}
trap cleanup EXIT INT TERM

step "Starting load test"

if [ "$MODE" = "in-cluster" ]; then
  ok "Tool: hey (in-cluster pod '$LOADGEN', image $HEY_IMAGE)"
  kubectl run "$LOADGEN" -n myapp --rm -i --restart=Never --image="$HEY_IMAGE" \
    -- -z "${DURATION}s" -c "$CONCURRENCY" "$CPU_URL"
elif command -v hey &>/dev/null; then
  ok "Tool: hey"
  hey -z "${DURATION}s" -c "$CONCURRENCY" "$CPU_URL"
elif command -v ab &>/dev/null; then
  ok "Tool: ab (apache bench)"
  ab -t "$DURATION" -c "$CONCURRENCY" "${CPU_URL}/"
elif command -v wrk &>/dev/null; then
  ok "Tool: wrk"
  wrk -d "${DURATION}s" -c "$CONCURRENCY" -t 4 "$CPU_URL"
else
  warn "hey/ab/wrk not found — falling back to curl loop (install hey for better results)"
  warn "  go install github.com/rakyll/hey@latest"
  END=$(($(date +%s) + DURATION))
  i=0
  while [ "$(date +%s)" -lt "$END" ]; do
    for _ in $(seq 1 "$CONCURRENCY"); do
      curl -s "$CPU_URL" -o /dev/null &
    done
    i=$((i + CONCURRENCY))
    echo -ne "  Sent ${i} requests...\r"
  done
  wait
  echo ""
fi
