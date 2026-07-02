#!/usr/bin/env bash
# ==============================================================================
# Setup script for `unified-node` — the non-disaggregated baseline used for
# comparison. g2-standard-16, 1x L4 (same GPU as one prefill/decode worker),
# running a single combined SGLang server.
#
# This instance is NOT part of the 3-node disaggregated cluster described in
# the architecture — it exists purely so the benchmark can compare unified vs
# disaggregated serving on equivalent per-worker hardware. Create it (empty,
# no startup-script metadata) with:
#   gcloud compute instances create unified-node \
#     --project=luminous-smithy-490001-i9 --zone=us-central1-a \
#     --machine-type=g2-standard-16 \
#     --accelerator=type=nvidia-l4,count=1 --maintenance-policy=TERMINATE \
#     --image=runara-base-sglang-1781835894
#
# (pinned to the exact image; swap to --image-family=runara-base-sglang if you
# want new instances to always pick up the latest image in that family instead)
#
# Then set UNIFIED_NODE=unified-node in cluster/deploy.env and run
# cluster/deploy.sh — it pushes config/cluster.env and runs this script for
# you over SSH. It can also be pasted into the instance's "startup-script"
# metadata for self-healing on reboot, as long as
# /opt/runara/config/cluster.env already exists on disk (deploy.sh's job).
#
# Idempotent — safe to re-run any time.
# ==============================================================================
set -euo pipefail

if [ ! -f /opt/runara/config/cluster.env ]; then
  echo "ERROR: /opt/runara/config/cluster.env not found. Run cluster/deploy.sh" \
       "from your workstation first — it stages this file before running this script." >&2
  exit 1
fi

mkdir -p /opt/runara/bin /opt/runara/config

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
