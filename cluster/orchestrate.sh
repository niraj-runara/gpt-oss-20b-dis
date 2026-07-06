#!/usr/bin/env bash
# ==============================================================================
# orchestrate.sh — bring the disaggregated GPT-OSS-20B cluster up/down/status
# in the required order, over `gcloud compute ssh`:
#   1. prefill worker (prefill-node)
#   2. decode worker  (decode-node)
#   3. router + nginx (cpu-node)
#
# SGLang runs in Docker on each node. PD transfer is handled inside
# launch_server (mooncake_tcp) — no separate cache_server / kv_broker.
#
# Usage: ./orchestrate.sh {up|down|status|restart}
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster.env"

SSH_BASE=(gcloud compute ssh --zone="${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap)

remote_exec() {
  local instance="$1"; shift
  echo ">>> [${instance}] $*"
  "${SSH_BASE[@]}" "${instance}" --command "$*"
}

wait_http_remote() {
  local instance="$1" url="$2" timeout="${3:-300}"
  echo ">>> [${instance}] waiting for ${url} (timeout ${timeout}s)"
  remote_exec "${instance}" "curl -fsS -o /dev/null --retry-connrefused --retry 1000 --retry-delay 3 --retry-max-time ${timeout} -m 5 '${url}'"
}

start_prefill() {
  remote_exec "${PREFILL_NODE}" "sudo systemctl restart model-sync.service"
  remote_exec "${PREFILL_NODE}" "sudo systemctl restart prefill-worker.service"
  wait_http_remote "${PREFILL_NODE}" "http://127.0.0.1:${PREFILL_WORKER_PORT}/health" 1800
}

start_decode() {
  remote_exec "${DECODE_NODE}" "sudo systemctl restart model-sync.service"
  remote_exec "${DECODE_NODE}" "sudo systemctl restart decode-worker.service"
  wait_http_remote "${DECODE_NODE}" "http://127.0.0.1:${DECODE_WORKER_PORT}/health" 1800
}

start_router_and_nginx() {
  remote_exec "${CPU_NODE}" "sudo systemctl restart router.service"
  wait_http_remote "${CPU_NODE}" "http://127.0.0.1:${ROUTER_PORT}/health" 1800
  remote_exec "${CPU_NODE}" "sudo systemctl reload nginx || sudo systemctl restart nginx"
}

cluster_up() {
  echo "=== 1/3 prefill worker ==="; start_prefill
  echo "=== 2/3 decode worker ==="; start_decode
  echo "=== 3/3 router + nginx ==="; start_router_and_nginx
  echo "Cluster is up."
}

cluster_down() {
  remote_exec "${CPU_NODE}" "sudo systemctl stop nginx || true"
  remote_exec "${CPU_NODE}" "sudo systemctl stop router.service || true"
  remote_exec "${DECODE_NODE}" "sudo systemctl stop decode-worker.service || true"
  remote_exec "${PREFILL_NODE}" "sudo systemctl stop prefill-worker.service || true"
  echo "Cluster is down."
}

cluster_status() {
  local pairs=(
    "${PREFILL_NODE}:prefill-worker.service"
    "${DECODE_NODE}:decode-worker.service"
    "${CPU_NODE}:router.service"
    "${CPU_NODE}:nginx"
  )
  for pair in "${pairs[@]}"; do
    local instance="${pair%%:*}" svc="${pair##*:}"
    local status
    status=$("${SSH_BASE[@]}" "${instance}" --command "systemctl is-active ${svc}" 2>/dev/null || echo "unreachable")
    printf "%-14s %-24s %s\n" "${instance}" "${svc}" "${status}"
  done
}

case "${1:-}" in
  up)      cluster_up ;;
  down)    cluster_down ;;
  status)  cluster_status ;;
  restart) cluster_down; cluster_up ;;
  *)
    echo "Usage: $0 {up|down|status|restart}" >&2
    exit 1
    ;;
esac
