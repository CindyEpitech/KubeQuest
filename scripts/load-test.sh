#!/bin/bash
# load-test.sh — Hammer /cpu to trigger HPA scaling
# Usage: ./load-test.sh [URL] [duration_seconds] [concurrency]
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${CYAN}==> $(date +%H:%M:%S) $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓  $*${NC}"; }
warn() { echo -e "${YELLOW}  !  $*${NC}"; }

APP_URL="${1:-http://app.kubequest.local}"
DURATION="${2:-120}"
CONCURRENCY="${3:-30}"

CPU_URL="${APP_URL%/}/cpu"

step "Pre-flight"
if ! kubectl get hpa -n myapp &>/dev/null; then
  warn "Cannot reach cluster — is kubectl configured?"
fi
ok "Target:      $CPU_URL"
ok "Duration:    ${DURATION}s"
ok "Concurrency: $CONCURRENCY workers"

step "HPA state before load"
kubectl get hpa -n myapp
echo ""
kubectl get pods -n myapp --no-headers | grep -v mysql | grep -v backup || true

step "Launching watchers (Ctrl+C to stop)"
# Open two background watches and store PIDs
kubectl get hpa -n myapp -w 2>/dev/null &
HPA_PID=$!
kubectl get pods -n myapp -w 2>/dev/null &
POD_PID=$!

cleanup() {
  kill "$HPA_PID" "$POD_PID" 2>/dev/null || true
  echo ""
  step "Final HPA state"
  kubectl get hpa -n myapp
  echo ""
  step "Final pod count"
  kubectl get pods -n myapp --no-headers | grep -v mysql | grep -v backup || true
}
trap cleanup EXIT INT TERM

step "Starting load test"

if command -v hey &>/dev/null; then
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
