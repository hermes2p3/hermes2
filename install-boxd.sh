#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Automated installer for Boxd
#  Based on Official Boxd Documentation (docs.boxd.sh)
# ============================================================

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }

# --- Ports ---
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock
NODE_BUILD_OPTS="--max-old-space-size=8192"

# --- Boxd Environment Setup ---
VM_NAME="${BOXD_BOX_ID:-${BOX_ID:-$(hostname)}}"

info "Boxd Machine Name: ${VM_NAME}"

# ============================================================
# Step 1: Configure Boxd Reverse Proxy (Official Boxd Logic)
# ============================================================
log "━━━ Step 1: Configuring Boxd Network & Proxies ━━━"

if command -v boxd &>/dev/null; then
    # Set default URL (https://<VM_NAME>.boxd.sh) to point to Hermes Studio port
    boxd proxy set-port --port=${HERMES_PORT} || warn "Could not set default port via boxd CLI."
    
    # Create subdomain proxy (https://router.<VM_NAME>.boxd.sh) for 9Router
    boxd proxy new router --port=${ROUTER_PORT} || warn "Subdomain proxy 'router' already exists or failed."
else
    warn "'boxd' CLI command not found. Ensure proxy is configured manually via ssh boxd.sh proxy."
fi

# ============================================================
# Step 2: Install Dependencies (Node.js & Python 3.12)
# ============================================================
log "━━━ Step 2: System Dependencies ━━━"

if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 23 ]; then
    log "Installing Node.js 24..."
    curl -fsSL "https://nodejs.org/dist/v24.15.0/node-v24.15.0-linux-x64.tar.gz" -o /tmp/node.tar.gz
    mkdir -p /usr/local/node-v24
    tar -xzf /tmp/node.tar.gz -C /usr/local/node-v24 --strip-components=1
    rm -f /tmp/node.tar.gz
    ln -sf /usr/local/node-v24/bin/node /usr/local/bin/node
    ln -sf /usr/local/node-v24/bin/npm /usr/local/bin/npm
fi

if [ ! -f /opt/python3.12/bin/python3 ]; then
    log "Installing Python 3.12..."
    curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/20260623/cpython-3.12.13%2B20260623-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" -o /tmp/python.tar.gz
    mkdir -p /opt/python3.12
    tar -xzf /tmp/python.tar.gz -C /opt/python3.12 --strip-components=1
    rm -f /tmp/python.tar.gz
fi

# ============================================================
# Step 3: Install hermes-agent
# ============================================================
log "━━━ Step 3: Install hermes-agent ━━━"
if [ ! -f /opt/hermes-venv/bin/hermes ]; then
    /opt/python3.12/bin/python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip -q
    /opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
fi

# ============================================================
# Step 4: Build Hermes Studio & 9Router
# ============================================================
log "━━━ Step 4: Building Applications ━━━"

if [ ! -d /root/hermes-studio/dist ]; then
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /root/hermes-studio
    cd /root/hermes-studio
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${HERMES_PORT} npm run build
    npm rebuild node-pty 2>/dev/null || true
fi

if [ ! -d /root/9router/dist ] && [ ! -d /root/9router/.next ]; then
    git clone --depth 1 https://github.com/decolua/9router.git /root/9router
    cd /root/9router
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} npm run build
fi

# ============================================================
# Step 5: Configure 9Router & Hermes
# ============================================================
log "━━━ Step 5: Configurations ━━━"

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
BASE_URL=http://localhost:${ROUTER_PORT}
HOSTNAME=0.0.0.0
EOF

mkdir -p /root/.hermes
if [ ! -f /root/.hermes/config.yaml ]; then
    cat > /root/.hermes/config.yaml << 'EOF'
model:
  default: oc/mimo-v2.5-free
  provider: custom:local-router
custom_providers:
  - name: local-router
    base_url: http://127.0.0.1:20127/v1
    api_key: ''
    model: oc/mimo-v2.5-free
    api_mode: chat_completions
    models:
      oc/mimo-v2.5-free:
        context_length: 1000000
EOF
fi

# ============================================================
# Step 6: Start Services
# ============================================================
log "━━━ Step 6: Start Services ━━━"

pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
sleep 2

# Bridge
export PATH=/opt/hermes-venv/bin:$PATH
nohup setsid /opt/python3.12/bin/python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &

# 9Router
cd /root/9router
NODE_ENV=production nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &

# Hermes Studio
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &

sleep 5

# ============================================================
# Display Correct Boxd URLs
# ============================================================
echo ""
echo -e "${GREEN}━━━ Deployment Complete! ━━━${NC}"
echo ""
echo -e "${YELLOW}Official Boxd Public URLs:${NC}"
echo -e "  Hermes Studio: ${BLUE}https://${VM_NAME}.boxd.sh${NC}"
echo -e "  9Router:       ${BLUE}https://router.${VM_NAME}.boxd.sh${NC}"
echo ""
echo -e "${YELLOW}Logins:${NC}"
echo -e "  Hermes: admin / 123456"
echo -e "  9Router Password: ${BLUE}${ROUTER_PASSWORD}${NC}"
echo ""
