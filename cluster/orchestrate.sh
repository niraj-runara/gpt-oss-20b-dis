#!/usr/bin/env bash
# ==============================================================================
# orchestrate.sh — bring the disaggregated GPT-OSS-20B cluster up/down/status
# in the required order, over `gcloud compute ssh`:
#   1. cache_server   (cpu-node)
#   2. kv_broker      (cpu-node)
#   3. prefill worker (prefill-node)
#   4. decode worker  (decode-node)
#   5. router + nginx (cpu-node)
#
# Each instance's own systemd units already self-order via wait_for.sh (see
# cluster/startup-scripts/*.sh), so this script is a safety net / explicit
# control plane for first bring-up, manual restarts, and status checks — not
# the only thing enforcing ordering.
#
# Requires: gcloud CLI authenticated, IAP tunneling enabled (or drop
# --tunnel-through-iap below if you use external IPs + firewall rules instead).
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

wait_tcp_remote() {
  local instance="$1" host="$2" port="$3" timeout="${4:-300}"
  echo ">>> [${instance}] waiting for ${host}:${port} (timeout ${timeout}s)"
  remote_exec "${instance}" "timeout ${timeout} bash -c 'until (exec 3<>/dev/tcp/${host}/${port}) 2>/dev/null; do sleep 2; done'"
}

wait_http_remote() {
  local instance="$1" url="$2" timeout="${3:-300}"
  echo ">>> [${instance}] waiting for ${url} (timeout ${timeout}s)"
  remote_exec "${instance}" "curl -fsS -o /dev/null --retry-connrefused --retry 1000 --retry-delay 3 --retry-max-time ${timeout} -m 5 '${url}'"
}

start_cache_server() {
  remote_exec "${CPU_NODE}" "sudo systemctl restart cache-server.service"
  wait_tcp_remote "${CPU_NODE}" "127.0.0.1" "${CACHE_SERVER_PORT}" 60
}

start_kv_broker() {
  remote_exec "${CPU_NODE}" "sudo systemctl restart kv-broker.service"
  wait_tcp_remote "${CPU_NODE}" "127.0.0.1" "${KV_BROKER_PORT}" 60
}

start_prefill() {
  remote_exec "${PREFILL_NODE}" "sudo systemctl restart model-sync.service"
  remote_exec "${PREFILL_NODE}" "sudo systemctl restart prefill-worker.service"
  wait_http_remote "${PREFILL_NODE}" "http://127.0.0.1:${PREFILL_WORKER_PORT}/health" 600
}

start_decode() {
  remote_exec "${DECODE_NODE}" "sudo systemctl restart model-sync.service"
  remote_exec "${DECODE_NODE}" "sudo systemctl restart decode-worker.service"
  wait_http_remote "${DECODE_NODE}" "http://127.0.0.1:${DECODE_WORKER_PORT}/health" 600
}

start_router_and_nginx() {
  remote_exec "${CPU_NODE}" "sudo systemctl restart router.service"
  wait_http_remote "${CPU_NODE}" "http://127.0.0.1:${ROUTER_PORT}/health" 300
  remote_exec "${CPU_NODE}" "sudo systemctl reload nginx || sudo systemctl restart nginx"
}

cluster_up() {
  echo "=== 1/5 cache_server ==="; start_cache_server
  echo "=== 2/5 kv_broker ==="; start_kv_broker
  echo "=== 3/5 prefill worker ==="; start_prefill
  echo "=== 4/5 decode worker ==="; start_decode
  echo "=== 5/5 router + nginx ==="; start_router_and_nginx
  echo "Cluster is up."
}

cluster_down() {
  remote_exec "${CPU_NODE}" "sudo systemctl stop nginx || true"
  remote_exec "${CPU_NODE}" "sudo systemctl stop router.service || true"
  remote_exec "${DECODE_NODE}" "sudo systemctl stop decode-worker.service || true"
  remote_exec "${PREFILL_NODE}" "sudo systemctl stop prefill-worker.service || true"
  remote_exec "${CPU_NODE}" "sudo systemctl stop kv-broker.service || true"
  remote_exec "${CPU_NODE}" "sudo systemctl stop cache-server.service || true"
  echo "Cluster is down."
}

cluster_status() {
  local pairs=(
    "${CPU_NODE}:cache-server.service"
    "${CPU_NODE}:kv-broker.service"
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
