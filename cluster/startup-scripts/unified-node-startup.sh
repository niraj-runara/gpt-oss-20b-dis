#!/usr/bin/env bash
# ==============================================================================
# GCE metadata startup-script for `unified-node` — the non-disaggregated
# baseline used for comparison. g2-standard-16, 1x L4 (same GPU as one
# prefill/decode worker), running a single combined SGLang server.
#
# This instance is NOT part of the 3-node disaggregated cluster described in
# the architecture — it exists purely so the benchmark can compare unified vs
# disaggregated serving on equivalent per-worker hardware. Create it with:
#   gcloud compute instances create unified-node \
#     --zone=us-central1-a --machine-type=g2-standard-16 \
#     --accelerator=type=nvidia-l4,count=1 --maintenance-policy=TERMINATE \
#     --image-family=runara-base-sglang --image-project=<your-image-project> \
#     --metadata-from-file startup-script=unified-node-startup.sh
#
# Idempotent — safe to re-run on every boot / reset.
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
# Combined (non-disaggregated) SGLang server
# ---------------------------------------------------------------------------
cat > /opt/runara/bin/run_unified_server.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
exec "${SGLANG_PYTHON}" -m sglang.launch_server \
  --model-path "${MODEL_LOCAL_DIR}" \
  --host 0.0.0.0 \
  --port "${UNIFIED_SERVER_PORT}" \
  --tp-size "${SGLANG_TP_SIZE}" \
  --mem-fraction-static "${SGLANG_MEM_FRACTION}" \
  --quantization fp8
EOF
chmod +x /opt/runara/bin/run_unified_server.sh

cat > /etc/systemd/system/unified-server.service <<'EOF'
[Unit]
Description=SGLang unified (combined prefill+decode) server
After=network-online.target model-sync.service
Requires=model-sync.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_unified_server.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# nginx: expose on port 80 too, so unified and disaggregated share the same
# "http://<ip>" convention for the benchmark client.
# ---------------------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y nginx
fi

cat > /etc/nginx/sites-available/runara-unified <<'EOF'
upstream runara_unified {
    server 127.0.0.1:30000;
}

server {
    listen 80 default_server;

    location / {
        proxy_pass http://runara_unified;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/runara-unified /etc/nginx/sites-enabled/runara-unified
nginx -t

systemctl daemon-reload
systemctl enable --now model-sync.service
systemctl enable --now unified-server.service
systemctl enable --now nginx

echo "unified-node startup script complete."
