#!/usr/bin/env bash
# ==============================================================================
# deploy-unified.sh — set up ONLY the unified baseline instance.
#
# Does not touch the disaggregated cluster (cpu/prefill/decode) or run
# orchestrate.sh. Pushes cluster.env, installs model-sync + unified-server +
# nginx on unified-node, and waits for /health.
#
# Prereqs:
#   - unified-node VM already created (empty, from runara-base-sglang image)
#   - cluster/deploy.env has UNIFIED_NODE set
#
# Usage: ./cluster/deploy-unified.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/deploy.env"

: "${PROJECT_ID:?set in cluster/deploy.env}"
: "${ZONE:?set in cluster/deploy.env}"
: "${UNIFIED_NODE:?set UNIFIED_NODE in cluster/deploy.env}"

GCLOUD_SSH=(gcloud compute ssh --zone="${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap)
GCLOUD_SCP=(gcloud compute scp --zone="${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap)

CLUSTER_ENV="${SCRIPT_DIR}/../config/cluster.env"
cat > "${CLUSTER_ENV}" <<EOF
export PROJECT_ID="${PROJECT_ID}"
export ZONE="${ZONE}"

export CPU_NODE="${CPU_NODE}"
export PREFILL_NODE="${PREFILL_NODE}"
export DECODE_NODE="${DECODE_NODE}"
export UNIFIED_NODE="${UNIFIED_NODE}"

export CPU_NODE_HOST="${CPU_NODE}"
export PREFILL_NODE_HOST="${PREFILL_NODE}"
export DECODE_NODE_HOST="${DECODE_NODE}"
export UNIFIED_NODE_HOST="${UNIFIED_NODE}"

export MODEL_GCS_PATH="gs://runara-models-gcp/gpt-oss-20b-fp8"
export MODEL_LOCAL_DIR="/mnt/models/gpt-oss-20b-fp8"

export SGLANG_DOCKER_IMAGE="lmsysorg/sglang:v0.5.13-cu129"
export SGLANG_DOCKER_SHM_SIZE="16g"
export SGLANG_TP_SIZE=2
export SGLANG_MEM_FRACTION=0.85
export DISAGG_TRANSFER_BACKEND="mooncake_tcp"
export DISAGG_BOOTSTRAP_PORT=9000

export PREFILL_WORKER_PORT=30000
export DECODE_WORKER_PORT=30001
export ROUTER_PORT=8000
export UNIFIED_SERVER_PORT=30000
export NGINX_PORT=80
EOF
echo "Rendered ${CLUSTER_ENV}"

echo ">>> [${UNIFIED_NODE}] pushing cluster.env + L4 MoE configs"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo mkdir -p /opt/runara/config /opt/runara/moe-configs"
"${GCLOUD_SCP[@]}" "${CLUSTER_ENV}" "${UNIFIED_NODE}:/tmp/cluster.env"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo mv /tmp/cluster.env /opt/runara/config/cluster.env"
"${GCLOUD_SCP[@]}" "${SCRIPT_DIR}/moe-configs/"*.json "${UNIFIED_NODE}:/tmp/"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo mv /tmp/E=*.json /opt/runara/moe-configs/"

echo ">>> [${UNIFIED_NODE}] running unified-node-startup.sh"
"${GCLOUD_SCP[@]}" "${SCRIPT_DIR}/startup-scripts/unified-node-startup.sh" "${UNIFIED_NODE}:/tmp/setup.sh"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo bash /tmp/setup.sh"

echo ">>> [${UNIFIED_NODE}] starting model sync + unified server"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo systemctl restart model-sync.service"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo systemctl restart unified-server.service"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command "sudo systemctl reload nginx || sudo systemctl restart nginx"

echo ">>> [${UNIFIED_NODE}] waiting for /health (up to 30 min for model sync + load)"
"${GCLOUD_SSH[@]}" "${UNIFIED_NODE}" --command \
  "curl -fsS -o /dev/null --retry-connrefused --retry 600 --retry-delay 3 --retry-max-time 1800 -m 5 http://127.0.0.1:30000/health"

echo "Unified node is up on port 80 (nginx) and ${UNIFIED_SERVER_PORT} (direct)."
