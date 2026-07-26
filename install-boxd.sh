#!/bin/bash
# ============================================================
#  Full Setup & Fix Script for Boxd (Hermes Studio + 9Router)
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Ports & Configuration ---
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock

# دریافت شناسه دقیق باکس از سیستم
BOX_ID="${BOXD_BOX_ID:-${BOX_ID:-$(hostname)}}"
BOX_ID=$(echo "$BOX_ID" | tr -d ' \t\n\r')

log "Setting up workspace for Box ID: ${BOX_ID}..."

# ============================================================
# 1. Kill old hanging processes
# ============================================================
log "Cleaning up old processes..."
pkill -f 'node' 2>/dev/null || true
pkill -f 'python' 2>/dev/null || true
sleep 2

# ============================================================
# 2. Dependencies (Node.js & Python)
# ============================================================
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
    log "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs -q
fi

if ! command -v python3.12 &>/dev/null; then
    log "Installing Python 3.12..."
    apt-get update -q && apt-get install -y python3.12 python3.12-venv python3-pip -q
fi

# ============================================================
# 3. Virtual Environment & Hermes Agent
# ============================================================
log "Setting up Python environment..."
mkdir -p /opt/hermes-venv
python3.12 -m venv /opt/hermes-venv
/opt/hermes-venv/bin/pip install --upgrade pip -q
/opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q

# ============================================================
# 4. Clone & Build Applications
# ============================================================
# 9Router
if [ ! -d /root/9router ]; then
    log "Cloning 9Router..."
    git clone --depth 1 https://github.com/decolua/9router.git /root/9router
fi
cd /root/9router
npm install --no-audit --no-fund
npm run build

# Hermes Studio
if [ ! -d /root/hermes-studio ]; then
    log "Cloning Hermes Studio..."
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /root/hermes-studio
fi
cd /root/hermes-studio
npm install --no-audit --no-fund
npm run build
npm rebuild node-pty 2>/dev/null || true

# ============================================================
# 5. Environments & Secrets Setup
# ============================================================
read -r ROUTER_PASSWORD JWT_SECRET API_KEY_SECRET MACHINE_ID_SALT < <(/opt/python3.12/bin/python3 -c "
import secrets
print(secrets.token_urlsafe(16), secrets.token_urlsafe(48), secrets.token_urlsafe(32), secrets.token_urlsafe(32))
")

cat > /root/9router/.env << EOF
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${ROUTER_PASSWORD}
DATA_DIR=/var/lib/9router
PORT=${ROUTER_PORT}
NODE_ENV=production
API_KEY_SECRET=${API_KEY_SECRET}
MACHINE_ID_SALT=${MACHINE_ID_SALT}
REQUIRE_API_KEY=false
BASE_URL=https://${ROUTER_PORT}-${BOX_ID}.proxy.boxd.sh
HOSTNAME=0.0.0.0
EOF

mkdir -p /root/.hermes
cat > /root/.hermes/config.yaml << EOF
model:
  default: oc/mimo-v2.5-free
  provider: custom:local-router
custom_providers:
  - name: local-router
    base_url: http://0.0.0.0:${ROUTER_PORT}/v1
    api_key: ''
    model: oc/mimo-v2.5-free
    api_mode: chat_completions
    models:
      oc/mimo-v2.5-free:
        context_length: 1000000
EOF

# ============================================================
# 6. Launch Processes (Binding explicitly to 0.0.0.0)
# ============================================================
log "Starting Services..."

# Agent Bridge
nohup /opt/hermes-venv/bin/python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 &

# 9Router
cd /root/9router
HOST=0.0.0.0 PORT=$ROUTER_PORT NODE_ENV=production nohup npm run start > /tmp/9router.log 2>&1 &

# Hermes Studio
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages

HOST=0.0.0.0 PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup node dist/server/index.js > /tmp/hermes.log 2>&1 &

sleep 5

# ============================================================
# 7. Local Port Verification
# ============================================================
log "Verifying local application responses..."

if curl -s http://127.0.0.1:${HERMES_PORT} >/dev/null; then
    log "Hermes Studio is healthy on local port ${HERMES_PORT}."
else
    warn "Hermes Studio failed to start locally! Check /tmp/hermes.log"
fi

if curl -s http://127.0.0.1:${ROUTER_PORT} >/dev/null; then
    log "9Router is healthy on local port ${ROUTER_PORT}."
else
    warn "9Router failed to start locally! Check /tmp/9router.log"
fi

# ============================================================
# Final Output
# ============================================================
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN} Deployment Finished! ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Access URLs for Boxd:"
echo -e "  Hermes Studio: \033[1;34mhttps://${HERMES_PORT}-${BOX_ID}.proxy.boxd.sh\033[0m"
echo -e "  9Router:       \033[1;34mhttps://${ROUTER_PORT}-${BOX_ID}.proxy.boxd.sh\033[0m"
echo -e "----------------------------------------------------"
echo -e "Credentials:"
echo -e "  Hermes Login: admin / 123456"
echo -e "  9Router Password: \033[1;33m${ROUTER_PASSWORD}\033[0m"
echo -e "${GREEN}====================================================${NC}\n"
