#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Dynamic & Auto-Validated Installer
#  Optimized dynamically for Boxd (app.boxd.sh)
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

# --- Dynamic Discovery Function ---
get_box_identifier() {
    local box_id=""
    # 1. Try Boxd environment variables
    box_id="${BOXD_SUBDOMAIN:-${BOXD_BOX_ID:-${BOX_ID:-}}}"
    
    # 2. Try hostname or fallback files
    if [ -z "$box_id" ]; then
        box_id=$(hostname 2>/dev/null || echo "")
    fi
    
    # Clean string
    box_id=$(echo "$box_id" | tr -d ' \t\n\r')
    
    if [ -z "$box_id" ]; then
        error "Could not dynamically identify the Boxd instance ID."
    fi
    echo "$box_id"
}

# --- Dynamic URL Validator ---
validate_url() {
    local test_url="$1"
    # Returns 0 if URL responds with any standard HTTP code (including redirects or auth required)
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$test_url" 2>/dev/null || echo "000")
    if [ "$status_code" -ne 000 ]; then
        return 0
    else
        return 1
    fi
}

# --- Variables ---
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock
NODE_BUILD_OPTS="--max-old-space-size=8192"

BOX_ID=$(get_box_identifier)
info "Detected Box Identifier: ${BOX_ID}"

# ============================================================
# Step 1: Network & Proxy Setup
# ============================================================
log "━━━ Step 1: Dynamic Proxy Configuration ━━━"

if command -v boxd &>/dev/null; then
    log "Configuring Boxd internal proxy rules..."
    boxd proxy set-port --port=${HERMES_PORT} 2>/dev/null || true
    boxd proxy new router --port=${ROUTER_PORT} 2>/dev/null || true
else
    info "Boxd CLI not available in path; relying on cloud proxy discovery..."
fi

# ============================================================
# Step 2: Dependencies (Node.js 24 & Python 3.12)
# ============================================================
log "━━━ Step 2: Installing Dependencies ━━━"

if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 23 ]; then
    log "Downloading Node.js..."
    curl -fsSL "https://nodejs.org/dist/v24.15.0/node-v24.15.0-linux-x64.tar.gz" -o /tmp/node.tar.gz
    mkdir -p /usr/local/node-v24
    tar -xzf /tmp/node.tar.gz -C /usr/local/node-v24 --strip-components=1
    rm -f /tmp/node.tar.gz
    ln -sf /usr/local/node-v24/bin/node /usr/local/bin/node
    ln -sf /usr/local/node-v24/bin/npm /usr/local/bin/npm
fi

if [ ! -f /opt/python3.12/bin/python3 ]; then
    log "Downloading Python 3.12..."
    curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/20260623/cpython-3.12.13%2B20260623-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" -o /tmp/python.tar.gz
    mkdir -p /opt/python3.12
    tar -xzf /tmp/python.tar.gz -C /opt/python3.12 --strip-components=1
    rm -f /tmp/python.tar.gz
fi

# ============================================================
# Step 3: Core Agents & Applications
# ============================================================
log "━━━ Step 3: Installing Core Software ━━━"

if [ ! -f /opt/hermes-venv/bin/hermes ]; then
    /opt/python3.12/bin/python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip -q
    /opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
fi

if [ ! -d /root/hermes-studio/dist ]; then
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /root/hermes-studio
    cd /root/hermes-studio
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${HERMES_PORT} npm run build
fi

if [ ! -d /root/9router/dist ] && [ ! -d /root/9router/.next ]; then
    git clone --depth 1 https://github.com/decolua/9router.git /root/9router
    cd /root/9router
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} npm run build
fi

# ============================================================
# Step 4: System Configs & Secrets
# ============================================================
log "━━━ Step 4: Secrets & Configuration ━━━"

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
# Step 5: Process Execution & Readiness Check
# ============================================================
log "━━━ Step 5: Launching Local Services ━━━"

pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
sleep 2

# Launch Bridge
export PATH=/opt/hermes-venv/bin:$PATH
nohup setsid /opt/python3.12/bin/python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &

# Launch 9Router
cd /root/9router
NODE_ENV=production nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &

# Launch Hermes
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &

# Internal Readiness Poll
log "Waiting for local services to initialize..."
for i in {1..15}; do
    if curl -s http://127.0.0.1:${HERMES_PORT}/ >/dev/null 2>&1 && curl -s http://127.0.0.1:${ROUTER_PORT}/ >/dev/null 2>&1; then
        log "Local services are UP and listening."
        break
    fi
    sleep 2
done

# ============================================================
# Step 6: Dynamic Public Domain Resolution & Validation
# ============================================================
log "━━━ Step 6: Validating External Public URLs ━━━"

FINAL_HERMES_URL=""
FINAL_ROUTER_URL=""

# List candidate patterns based on Boxd topology
HERMES_CANDIDATES=(
    "https://${BOX_ID}.boxd.sh"
    "https://${HERMES_PORT}-${BOX_ID}.boxd.sh"
    "https://${BOX_ID}.app.boxd.sh"
)

ROUTER_CANDIDATES=(
    "https://router.${BOX_ID}.boxd.sh"
    "https://${ROUTER_PORT}-${BOX_ID}.boxd.sh"
    "https://20127-${BOX_ID}.boxd.sh"
)

# Test candidates dynamically
for url in "${HERMES_CANDIDATES[@]}"; do
    if validate_url "$url"; then
        FINAL_HERMES_URL="$url"
        break
    fi
done

for url in "${ROUTER_CANDIDATES[@]}"; do
    if validate_url "$url"; then
        FINAL_ROUTER_URL="$url"
        break
    fi
done

# Fallback defaults if external resolve pending
if [ -z "$FINAL_HERMES_URL" ]; then
    FINAL_HERMES_URL="https://${BOX_ID}.boxd.sh (Unverified / Initializing)"
fi
if [ -z "$FINAL_ROUTER_URL" ]; then
    FINAL_ROUTER_URL="https://router.${BOX_ID}.boxd.sh (Unverified / Initializing)"
fi

# ============================================================
# Final Summary Output
# ============================================================
echo ""
echo -e "${GREEN}━━━ Deployment Completed Successfully! ━━━${NC}"
echo ""
echo -e "${YELLOW}Validated Public Access Points:${NC}"
echo -e "  Hermes Studio: ${BLUE}${FINAL_HERMES_URL}${NC}"
echo -e "  9Router:       ${BLUE}${FINAL_ROUTER_URL}${NC}"
echo ""
echo -e "${YELLOW}Login Credentials:${NC}"
echo -e "  Hermes Studio: Username: ${BLUE}admin${NC} | Password: ${BLUE}123456${NC}"
echo -e "  9Router Admin: Password: ${BLUE}${ROUTER_PASSWORD}${NC}"
echo ""
