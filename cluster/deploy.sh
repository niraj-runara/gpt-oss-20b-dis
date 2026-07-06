#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — one-shot setup for manually-created, empty instances.
#
# Prereqs:
#   - You already created the instances (from the runara-base-sglang image)
#     and can `gcloud compute ssh` into them.
#   - cluster/deploy.env is filled in with your project/zone/instance names.
#
# Per instance, this pushes:
#   1. A freshly rendered config/cluster.env (built from deploy.env, so it
#      always matches whatever you actually named your instances) to
#      /opt/runara/config/cluster.env
#   2. That instance's setup script, run once as root — installs systemd
#      units, the wait_for.sh health-check helper, and nginx where relevant.
#
# Then it hands off to orchestrate.sh, which brings everything up in the
# required order: prefill -> decode -> router+nginx.
#
# Usage: ./cluster/deploy.sh
# Idempotent — re-run any time after editing deploy.env or a startup script.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/deploy.env"

: "${PROJECT_ID:?set in cluster/deploy.env}"
: "${ZONE:?set in cluster/deploy.env}"
: "${CPU_NODE:?set in cluster/deploy.env}"
: "${PREFILL_NODE:?set in cluster/deploy.env}"
: "${DECODE_NODE:?set in cluster/deploy.env}"

GCLOUD_SSH=(gcloud compute ssh --zone="${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap)
GCLOUD_SCP=(gcloud compute scp --zone="${ZONE}" --project="${PROJECT_ID}" --tunnel-through-iap)

# ---------------------------------------------------------------------------
# Render config/cluster.env from deploy.env so orchestrate.sh and the
# benchmark scripts stay in sync with your actual instance names.
# ---------------------------------------------------------------------------
CLUSTER_ENV="${SCRIPT_DIR}/../config/cluster.env"
cat > "${CLUSTER_ENV}" <<EOF
export PROJECT_ID="${PROJECT_ID}"
export ZONE="${ZONE}"

export CPU_NODE="${CPU_NODE}"
export PREFILL_NODE="${PREFILL_NODE}"
export DECODE_NODE="${DECODE_NODE}"
export UNIFIED_NODE="${UNIFIED_NODE:-unified-node}"

export CPU_NODE_HOST="${CPU_NODE}"
export PREFILL_NODE_HOST="${PREFILL_NODE}"
export DECODE_NODE_HOST="${DECODE_NODE}"
export UNIFIED_NODE_HOST="${UNIFIED_NODE:-unified-node}"

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
echo "Rendered ${CLUSTER_ENV} from deploy.env"

push_cluster_env() {
  local instance="$1"
  echo ">>> [${instance}] pushing cluster.env"
  "${GCLOUD_SSH[@]}" "${instance}" --command "sudo mkdir -p /opt/runara/config /opt/runara/moe-configs"
  "${GCLOUD_SCP[@]}" "${CLUSTER_ENV}" "${instance}:/tmp/cluster.env"
  "${GCLOUD_SSH[@]}" "${instance}" --command "sudo mv /tmp/cluster.env /opt/runara/config/cluster.env"
  if [[ "${instance}" == "${PREFILL_NODE}" || "${instance}" == "${DECODE_NODE}" || "${instance}" == "${UNIFIED_NODE:-}" ]]; then
    echo ">>> [${instance}] pushing L4 MoE configs"
    "${GCLOUD_SCP[@]}" "${SCRIPT_DIR}/moe-configs/"*.json "${instance}:/tmp/"
    "${GCLOUD_SSH[@]}" "${instance}" --command "sudo mv /tmp/E=*.json /opt/runara/moe-configs/"
  fi
}

push_and_run_setup() {
  local instance="$1" script="$2"
  echo ">>> [${instance}] pushing and running $(basename "${script}")"
  "${GCLOUD_SCP[@]}" "${script}" "${instance}:/tmp/setup.sh"
  "${GCLOUD_SSH[@]}" "${instance}" --command "sudo bash /tmp/setup.sh"
}

setup_instance() {
  local instance="$1" script="${SCRIPT_DIR}/startup-scripts/$2"
  push_cluster_env "${instance}"
  push_and_run_setup "${instance}" "${script}"
}

echo "=== Setting up cpu-node (${CPU_NODE}) ==="
setup_instance "${CPU_NODE}" "cpu-node-startup.sh"

echo "=== Setting up prefill-node (${PREFILL_NODE}) ==="
setup_instance "${PREFILL_NODE}" "prefill-node-startup.sh"

echo "=== Setting up decode-node (${DECODE_NODE}) ==="
setup_instance "${DECODE_NODE}" "decode-node-startup.sh"

if [ -n "${UNIFIED_NODE:-}" ]; then
  echo "=== Setting up unified-node (${UNIFIED_NODE}) ==="
  setup_instance "${UNIFIED_NODE}" "unified-node-startup.sh"
fi

echo "=== All instances configured. Bringing cluster up in order... ==="
exec "${SCRIPT_DIR}/orchestrate.sh" up
