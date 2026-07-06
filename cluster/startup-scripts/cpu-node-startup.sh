#!/usr/bin/env bash
# ==============================================================================
# Setup script for `cpu-node` (n2-standard-8).
# Installs/updates and starts: sglang_router (PD mode) + nginx.
#
# SGLang runs inside Docker (lmsysorg/sglang) — not host python3.
# Upstream PD disaggregation uses launch_router on cpu-node; there is no
# separate cache_server or kv_broker.
# ==============================================================================
set -euo pipefail

if [ ! -f /opt/runara/config/cluster.env ]; then
  echo "ERROR: /opt/runara/config/cluster.env not found. Run cluster/deploy.sh" \
       "from your workstation first." >&2
  exit 1
fi

mkdir -p /opt/runara/bin /opt/runara/config

cat > /opt/runara/bin/wait_for.sh <<'EOF'
#!/usr/bin/env bash
# wait_for.sh tcp <host> <port> [timeout_s]   |   wait_for.sh http <url> [timeout_s]
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

# Remove legacy Runara-only services from earlier deploy attempts.
systemctl disable --now cache-server.service kv-broker.service 2>/dev/null || true
rm -f /etc/systemd/system/cache-server.service /etc/systemd/system/kv-broker.service
rm -f /opt/runara/bin/run_cache_server.sh /opt/runara/bin/run_kv_broker.sh

cat > /opt/runara/bin/run_router.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
/opt/runara/bin/wait_for.sh http "http://${PREFILL_NODE_HOST}:${PREFILL_WORKER_PORT}/health" 900
/opt/runara/bin/wait_for.sh http "http://${DECODE_NODE_HOST}:${DECODE_WORKER_PORT}/health" 900
docker rm -f sglang-router 2>/dev/null || true
exec docker run --name sglang-router \
  --network host \
  "${SGLANG_DOCKER_IMAGE}" \
  python3 -m sglang_router.launch_router \
  --pd-disaggregation \
  --prefill "http://${PREFILL_NODE_HOST}:${PREFILL_WORKER_PORT}" "${DISAGG_BOOTSTRAP_PORT}" \
  --decode "http://${DECODE_NODE_HOST}:${DECODE_WORKER_PORT}" \
  --host 0.0.0.0 \
  --port "${ROUTER_PORT}" \
  --policy round_robin \
  --worker-startup-timeout-secs 1800
EOF
chmod +x /opt/runara/bin/run_router.sh

cat > /etc/systemd/system/router.service <<'EOF'
[Unit]
Description=SGLang PD router (Docker)
After=network-online.target docker.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_router.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if ! command -v nginx >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y nginx
fi

cat > /etc/nginx/sites-available/runara-router <<'EOF'
upstream runara_router {
    server 127.0.0.1:8000;
}

server {
    listen 80 default_server;

    location / {
        proxy_pass http://runara_router;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/runara-router /etc/nginx/sites-enabled/runara-router
nginx -t

systemctl daemon-reload
systemctl enable --now router.service
systemctl enable --now nginx

echo "cpu-node startup script complete."
