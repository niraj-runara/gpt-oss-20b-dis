#!/usr/bin/env bash
# ==============================================================================
# Setup script for `cpu-node` (n2-standard-8).
# Installs/updates and starts: cache_server, kv_broker, router, nginx.
#
# Normally you don't run this by hand — cluster/deploy.sh pushes
# config/cluster.env to /opt/runara/config/cluster.env and then runs this
# script for you over SSH. It can also be pasted into the instance's
# "startup-script" metadata for self-healing on reboot, as long as
# /opt/runara/config/cluster.env already exists on disk (deploy.sh's job).
#
# Idempotent — safe to re-run any time.
#
# *** VERIFY BEFORE FIRST RUN ***
# sglang.cache_server / sglang.kv_broker / sglang.router are Runara's custom
# modules, not upstream SGLang. The flag names below (--cache-server-url,
# --kv-broker-url, --prefill/--decode, --policy) are best-guess conventions.
# Run each with --help on the boot image and fix run_*.sh below if they differ.
# Also verify whether cache_server/kv_broker expose an HTTP /health endpoint —
# this script assumes they don't and falls back to a plain TCP reachability
# check; switch wait_for.sh calls to "http ... /health" if they do.
# ==============================================================================
set -euo pipefail

if [ ! -f /opt/runara/config/cluster.env ]; then
  echo "ERROR: /opt/runara/config/cluster.env not found. Run cluster/deploy.sh" \
       "from your workstation first — it stages this file before running this script." >&2
  exit 1
fi

mkdir -p /opt/runara/bin /opt/runara/config

# ---------------------------------------------------------------------------
# Shared helper: block until a dependency is reachable/healthy, or fail.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Service launch wrappers
# ---------------------------------------------------------------------------
cat > /opt/runara/bin/run_cache_server.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
exec "${SGLANG_PYTHON}" -m sglang.cache_server \
  --host 0.0.0.0 \
  --port "${CACHE_SERVER_PORT}"
EOF

cat > /opt/runara/bin/run_kv_broker.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
/opt/runara/bin/wait_for.sh tcp 127.0.0.1 "${CACHE_SERVER_PORT}" 300
exec "${SGLANG_PYTHON}" -m sglang.kv_broker \
  --host 0.0.0.0 \
  --port "${KV_BROKER_PORT}" \
  --cache-server-url "http://127.0.0.1:${CACHE_SERVER_PORT}"
EOF

cat > /opt/runara/bin/run_router.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/runara/config/cluster.env
/opt/runara/bin/wait_for.sh http "http://${PREFILL_NODE_HOST}:${PREFILL_WORKER_PORT}/health" 900
/opt/runara/bin/wait_for.sh http "http://${DECODE_NODE_HOST}:${DECODE_WORKER_PORT}/health" 900
exec "${SGLANG_PYTHON}" -m sglang.router \
  --host 0.0.0.0 \
  --port "${ROUTER_PORT}" \
  --policy round_robin \
  --prefill "http://${PREFILL_NODE_HOST}:${PREFILL_WORKER_PORT}" \
  --decode "http://${DECODE_NODE_HOST}:${DECODE_WORKER_PORT}" \
  --kv-broker-url "http://127.0.0.1:${KV_BROKER_PORT}"
EOF

chmod +x /opt/runara/bin/run_cache_server.sh /opt/runara/bin/run_kv_broker.sh /opt/runara/bin/run_router.sh

# ---------------------------------------------------------------------------
# systemd units
# StartLimitIntervalSec=0 -> retry forever on failure (dependencies on other
# instances may not be up yet, especially on first cold boot of the cluster).
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/cache-server.service <<'EOF'
[Unit]
Description=SGLang cache_server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_cache_server.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/kv-broker.service <<'EOF'
[Unit]
Description=SGLang kv_broker
After=network-online.target cache-server.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/runara/bin/run_kv_broker.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/router.service <<'EOF'
[Unit]
Description=SGLang router (fans out to prefill/decode workers)
After=network-online.target kv-broker.service
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

# ---------------------------------------------------------------------------
# nginx: single stable public entrypoint, streaming-friendly reverse proxy
# ---------------------------------------------------------------------------
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
        proxy_buffering off;          # needed for SSE/streaming completions
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/runara-router /etc/nginx/sites-enabled/runara-router
nginx -t

# ---------------------------------------------------------------------------
# Enable + start everything local to this node. Boot ordering across
# instances is enforced by the wait_for.sh calls inside each run_*.sh, so
# this is safe to run at every boot regardless of whether prefill/decode
# nodes are up yet (kv-broker/router will just retry until they are).
# Use cluster/orchestrate.sh for an explicit, ordered first bring-up.
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now cache-server.service
systemctl enable --now kv-broker.service
systemctl enable --now router.service
systemctl enable --now nginx

echo "cpu-node startup script complete."
