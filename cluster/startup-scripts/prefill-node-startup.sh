#!/usr/bin/env bash
# ==============================================================================
# GCE metadata startup-script for `prefill-node` (g2-standard-16, 1x L4).
# Syncs model weights from GCS, then runs the SGLang prefill worker.
#
# Deploy with:
#   gcloud compute instances add-metadata prefill-node --zone=us-central1-a \
#     --metadata-from-file startup-script=prefill-node-startup.sh
#   gcloud compute instances reset prefill-node --zone=us-central1-a
#
# Idempotent — safe to re-run on every boot / reset.
#
# *** VERIFY BEFORE FIRST RUN ***
# --disaggregation-mode / --kv-broker-url / --cache-server-url are best-guess
# flag names for Runara's custom sglang build. Confirm with:
#   python3 -m sglang.launch_server --help
# on the runara-base-sglang image and adjust run_prefill_worker.sh if needed.
# ==============================================================================
set -euo pipefail

mkdir -p /opt/runara/bin /opt/runara/config

cat > /opt/runara/config/cluster.env <<'EOF'
export PROJECT_ID="luminous-smithy-490001-i9"
export ZONE="us-central1-a"

export CPU_NODE="cpu-node"
export PREFILL_NODE="prefill-node"
export DECODE_NODE="decode-node"
export UNIFIED_NODE="unified-node"

export CPU_NODE_HOST="cpu-node"
export PREFILL_NODE_HOST="prefill-node"
export DECODE_NODE_HOST="decode-node"
export UNIFIED_NODE_HOST="unified-node"

export MODEL_GCS_PATH="gs://runara-models-gcp/gpt-oss-20b-fp8"
export MODEL_LOCAL_DIR="/mnt/models/gpt-oss-20b-fp8"

export SGLANG_PYTHON="python3"
export SGLANG_TP_SIZE=1
export SGLANG_MEM_FRACTION=0.85

export CACHE_SERVER_PORT=8100
export KV_BROKER_PORT=8200
export PREFILL_WORKER_PORT=30000
export DECODE_WORKER_PORT=30001
export ROUTER_PORT=8000
export UNIFIED_SERVER_PORT=30000
export NGINX_PORT=80
EOF

cat > /opt/runara/bin/wait_for.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE="${1:?mode required: tcp|http}"; shift
TIMEOUT=60
if [ "$MODE" = "tcp" ]; then
  HOST="${1:?host required}"; PORT="${2:?port required}"; TIMEOUT="${3:-$TIMEOUT}"
elif [ "$MODE" = "http" ]; then
  URL="${1:?url required}"; TIMEOUT="${2:-$TIMEOUT}"
else
  echo "wait_for: unknown mode '$MODE'" >&2; exit 1
fi
deadline=$(( $(date +%s) + TIMEOUT ))
while true; do
  if [ "$MODE" = "tcp" ]; then
    if (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null; then
      exec 3>&- 3<&-
      echo "wait_for: ${HOST}:${PORT} reachable"; exit 0
    fi
  else
    if curl -fsS -o /dev/null -m 3 "$URL"; then
      echo "wait_for: ${URL} healthy"; exit 0
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "wait_for: TIMEOUT after ${TIMEOUT}s waiting on ${MODE} ${HOST:-$URL}${PORT:+:$PORT}" >&2
    exit 1
  fi
  sleep 2
done
EOF
chmod +x /opt/runara/bin/wait_for.sh

# ---------------------------------------------------------------------------
# Model sync (oneshot, runs once per boot, kept around via RemainAfterExit)
# ---------------------------------------------------------------------------
cat > /opt/runara/bin/run_model_sync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
mkdir -p "${MODEL_LOCAL_DIR}"
echo "Syncing model weights from ${MODEL_GCS_PATH} to ${MODEL_LOCAL_DIR} ..."
gcloud storage rsync -r "${MODEL_GCS_PATH}" "${MODEL_LOCAL_DIR}"
echo "Model sync complete."
EOF
chmod +x /opt/runara/bin/run_model_sync.sh

cat > /etc/systemd/system/model-sync.service <<'EOF'
[Unit]
Description=Sync GPT-OSS-20B FP8 weights from GCS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/runara/bin/run_model_sync.sh
RemainAfterExit=yes
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Prefill worker
# ---------------------------------------------------------------------------
cat > /opt/runara/bin/run_prefill_worker.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
/opt/runara/bin/wait_for.sh tcp "${CPU_NODE_HOST}" "${CACHE_SERVER_PORT}" 600
/opt/runara/bin/wait_for.sh tcp "${CPU_NODE_HOST}" "${KV_BROKER_PORT}" 600
exec "${SGLANG_PYTHON}" -m sglang.launch_server \
  --model-path "${MODEL_LOCAL_DIR}" \
  --host 0.0.0.0 \
  --port "${PREFILL_WORKER_PORT}" \
  --tp-size "${SGLANG_TP_SIZE}" \
  --mem-fraction-static "${SGLANG_MEM_FRACTION}" \
  --quantization fp8 \
  --disaggregation-mode prefill \
  --kv-broker-url "http://${CPU_NODE_HOST}:${KV_BROKER_PORT}" \
  --cache-server-url "http://${CPU_NODE_HOST}:${CACHE_SERVER_PORT}"
EOF
chmod +x /opt/runara/bin/run_prefill_worker.sh

cat > /etc/systemd/system/prefill-worker.service <<'EOF'
[Unit]
Description=SGLang prefill worker (disaggregated)
After=network-online.target model-sync.service
Requires=model-sync.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_prefill_worker.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now model-sync.service
systemctl enable --now prefill-worker.service

echo "prefill-node startup script complete."
