#!/usr/bin/env bash
# ==============================================================================
# Setup script for `decode-node` (g2-standard-24, 2x L4, tp-size 2).
# Syncs model weights from GCS, then runs the SGLang decode worker.
#
# Normally you don't run this by hand — cluster/deploy.sh pushes
# config/cluster.env to /opt/runara/config/cluster.env and then runs this
# script for you over SSH. It can also be pasted into the instance's
# "startup-script" metadata for self-healing on reboot, as long as
# /opt/runara/config/cluster.env already exists on disk (deploy.sh's job).
#
# Idempotent — safe to re-run any time.
#
# SGLang runs inside Docker (lmsysorg/sglang). Upstream PD decode worker.
# ==============================================================================
set -euo pipefail

if [ ! -f /opt/runara/config/cluster.env ]; then
  echo "ERROR: /opt/runara/config/cluster.env not found. Run cluster/deploy.sh" \
       "from your workstation first — it stages this file before running this script." >&2
  exit 1
fi

mkdir -p /opt/runara/bin /opt/runara/config /opt/runara/moe-configs

MOE_CONTAINER_CFG="/sgl-workspace/sglang/python/sglang/srt/layers/moe/moe_runner/triton_utils/configs/triton_3_6_0"

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
# Decode worker
# ---------------------------------------------------------------------------
cat > /opt/runara/bin/run_decode_worker.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
docker rm -f sglang-decode 2>/dev/null || true
exec docker run --name sglang-decode \\
  --gpus all \\
  --network host \\
  --shm-size "\${SGLANG_DOCKER_SHM_SIZE}" \\
  -v "\${MODEL_LOCAL_DIR}:\${MODEL_LOCAL_DIR}:ro" \\
  -v /opt/runara/moe-configs:${MOE_CONTAINER_CFG} \\
  "\${SGLANG_DOCKER_IMAGE}" \\
  python3 -m sglang.launch_server \\
  --model-path "\${MODEL_LOCAL_DIR}" \\
  --host 0.0.0.0 \\
  --port "\${DECODE_WORKER_PORT}" \\
  --tp-size "\${SGLANG_TP_SIZE}" \\
  --mem-fraction-static "\${SGLANG_MEM_FRACTION}" \\
  --quantization fp8 \\
  --disaggregation-mode decode \\
  --disaggregation-transfer-backend "\${DISAGG_TRANSFER_BACKEND}"
EOF
chmod +x /opt/runara/bin/run_decode_worker.sh

cat > /etc/systemd/system/decode-worker.service <<'EOF'
[Unit]
Description=SGLang decode worker (disaggregated)
After=network-online.target model-sync.service
Requires=model-sync.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_decode_worker.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now model-sync.service
systemctl enable --now decode-worker.service

echo "decode-node startup script complete."
