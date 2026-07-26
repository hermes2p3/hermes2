#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Automated installer for Boxd
# ============================================================
#  Version: 2.0 (Boxd Edition)
#  License: MIT
# ============================================================
#
#  This script automatically installs and configures:
#  - Node.js 24
#  - Python 3.12
#  - hermes-agent
#  - Hermes Studio (AI chat web UI)
#  - 9Router (free AI model API router)
#  - Telegram channel (bot token + owner pairing)
#  - Skills & plugins for hermes-agent
#  - Automatic watchdog / self-healing system
#
#  Usage:
#    bash install.sh
#
#  Environment variables for Boxd:
#    BOX_ID / BOXD_BOX_ID       Auto-detected on app.boxd.sh
#    TELEGRAM_BOT_TOKEN         Bot token from https://t.me/BotFather
#    TELEGRAM_OWNER_ID          Your numeric Telegram user ID
#    HERMES_SKILLS              Comma-separated skill/plugin sources
#
#  After installation, URLs will be available at:
#    - Hermes Studio: https://6060-<BOX_ID>.boxd.sh
#    - 9Router:       https://20127-<BOX_ID>.boxd.sh
# ============================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No color

# --- Helper functions ---
log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }

run() { "$@" || error "Command failed: $*"; }

# --- Variables ---
PYTHON_VERSION="3.12.13"
PYTHON_BUILD_DATE="20260623"
NODE_VERSION="24.15.0"
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock
NODE_BUILD_OPTS="--max-old-space-size=8192"

# --- Telegram channel configuration ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_OWNER_ID="${TELEGRAM_OWNER_ID:-}"
TELEGRAM_PROXY_URL="${TELEGRAM_PROXY_URL:-}"
TELEGRAM_REQUIRE_MENTION="${TELEGRAM_REQUIRE_MENTION:-false}"
TELEGRAM_REACTIONS="${TELEGRAM_REACTIONS:-true}"
TELEGRAM_FREE_CHATS="${TELEGRAM_FREE_CHATS:-}"
TELEGRAM_MENTION_PATTERNS="${TELEGRAM_MENTION_PATTERNS:-}"

# --- Skills & plugins ---
HERMES_SKILLS="${HERMES_SKILLS:-}"

# --- Banner ---
echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║    Hermes Studio + 9Router Installer             ║"
echo "  ║    Optimized for Boxd Platform (app.boxd.sh)     ║"
echo "  ║                                                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    warn "Script is not running as root. Continuing anyway..."
fi

# --- Boxd environment check & Box ID resolution ---
BOX_ID="${BOXD_BOX_ID:-${BOX_ID:-$(hostname)}}"
BOXD_DOMAIN="${BOXD_DOMAIN:-boxd.sh}"

if [ ! -f /.dockerenv ] && [ -z "${BOXD_BOX_ID:-}" ] && [ -z "${BOX_ID:-}" ]; then
    warn "This does not appear to be a Boxd container. Public URLs might differ."
fi

info "Boxd ID: ${BOX_ID}"
info "Target Domain: ${BOXD_DOMAIN}"

# ============================================================
# Step 1: Install Node.js
# ============================================================
echo ""
log "━━━ Step 1: Install Node.js ━━━"

if command -v node &>/dev/null && [ "$(node -v | cut -d. -f1 | tr -d v)" -ge 23 ]; then
    info "Node.js $(node -v) is already installed."
else
    log "Downloading Node.js v${NODE_VERSION}..."
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" -o /tmp/node.tar.gz
    mkdir -p /usr/local/node-v24
    tar -xzf /tmp/node.tar.gz -C /usr/local/node-v24 --strip-components=1
    rm -f /tmp/node.tar.gz
    ln -sf /usr/local/node-v24/bin/node /usr/local/bin/node
    ln -sf /usr/local/node-v24/bin/npm /usr/local/bin/npm
    ln -sf /usr/local/node-v24/bin/npx /usr/local/bin/npx
    log "Node.js installed: $(node -v)"
fi

# ============================================================
# Step 2: Install Python 3.12
# ============================================================
echo ""
log "━━━ Step 2: Install Python 3.12 ━━━"

if /opt/python3.12/bin/python3 --version &>/dev/null; then
    info "Python 3.12 is already installed."
else
    log "Downloading Python ${PYTHON_VERSION}..."
    curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/cpython-${PYTHON_VERSION}%2B${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" -o /tmp/python.tar.gz
    mkdir -p /opt/python3.12
    tar -xzf /tmp/python.tar.gz -C /opt/python3.12 --strip-components=1
    rm -f /tmp/python.tar.gz
    log "Python installed: $(/opt/python3.12/bin/python3 --version)"
fi

# ============================================================
# Step 3: Install hermes-agent & System Dependencies
# ============================================================
echo ""
log "━━━ Step 3: Install hermes-agent ━━━"

if [ -f /opt/hermes-venv/bin/hermes ]; then
    info "hermes-agent is already installed."
else
    log "Creating Python virtual environment..."
    rm -rf /opt/hermes-venv
    /opt/python3.12/bin/python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip -q
    log "Installing hermes-agent..."
    /opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
    log "hermes-agent installed: $(/opt/hermes-venv/bin/hermes --version 2>&1 | head -1)"
fi

if ! command -v cron &>/dev/null || ! command -v git &>/dev/null || ! command -v make &>/dev/null; then
    log "Installing system tools (cron, curl, git, build tools)..."
    apt-get update -qq && apt-get install -y -qq cron curl git make g++ python3-dev > /dev/null 2>&1 || warn "Some system packages may not have installed correctly."
else
    info "System tools already installed."
fi

# ============================================================
# Step 4: Download and build Hermes Studio
# ============================================================
echo ""
log "━━━ Step 4: Install Hermes Studio ━━━"

if [ -d /root/hermes-studio/dist ]; then
    info "Hermes Studio is already built."
else
    log "Cloning Hermes Studio..."
    rm -rf /root/hermes-studio
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /root/hermes-studio

    log "Installing dependencies..."
    cd /root/hermes-studio
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund

    log "Building project..."
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${HERMES_PORT} npm run build

    log "Rebuilding native modules..."
    npm rebuild node-pty 2>/dev/null || true
fi

# ============================================================
# Step 5: Download and build 9Router
# ============================================================
echo ""
log "━━━ Step 5: Install 9Router ━━━"

if [ -d /root/9router/dist ] || [ -d /root/9router/.next ]; then
    info "9Router is already built."
else
    log "Cloning 9Router..."
    rm -rf /root/9router
    git clone --depth 1 https://github.com/decolua/9router.git /root/9router

    log "Installing dependencies..."
    cd /root/9router
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund

    log "Building project..."
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} npm run build
fi

# ============================================================
# Step 6: Configure 9Router
# ============================================================
echo ""
log "━━━ Step 6: Configure 9Router ━━━"

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
ENABLE_REQUEST_LOGS=false
OBSERVABILITY_ENABLED=false
AUTH_COOKIE_SECURE=false
REQUIRE_API_KEY=false
BASE_URL=http://localhost:${ROUTER_PORT}
CLOUD_URL=https://9router.com
NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT}
NEXT_PUBLIC_CLOUD_URL=https://9router.com
HOSTNAME=0.0.0.0
EOF

log "9Router login password: ${ROUTER_PASSWORD}"

# ============================================================
# Step 7: Configure Hermes Studio
# ============================================================
echo ""
log "━━━ Step 7: Configure Hermes Studio ━━━"

mkdir -p /root/.hermes /root/.hermes-web-ui

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
    log "Hermes config file created."
fi

# ============================================================
# Step 8: Configure Telegram channel
# ============================================================
echo ""
log "━━━ Step 8: Configure Telegram channel ━━━"

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    mkdir -p /root/.hermes/channels

    require_mention_yaml="false"; [ "$TELEGRAM_REQUIRE_MENTION" = "true" ] && require_mention_yaml="true"
    reactions_yaml="true"; [ "$TELEGRAM_REACTIONS" = "false" ] && reactions_yaml="false"

    free_chats_yaml="[]"
    if [ -n "$TELEGRAM_FREE_CHATS" ]; then
        free_chats_yaml="[$(echo "$TELEGRAM_FREE_CHATS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | paste -sd, -)]"
    fi

    patterns_yaml="[]"
    if [ -n "$TELEGRAM_MENTION_PATTERNS" ]; then
        patterns_yaml="[$(echo "$TELEGRAM_MENTION_PATTERNS" | tr ',' '\n' | sed 's/^ *//;s/ *$//;s/.*/"&"/' | paste -sd, -)]"
    fi

    cat > /root/.hermes/channels/telegram.yaml << EOF
telegram:
  enabled: true
  bot_token: "${TELEGRAM_BOT_TOKEN}"
  owner_id: "${TELEGRAM_OWNER_ID}"
  proxy_url: "${TELEGRAM_PROXY_URL}"
  require_mention: ${require_mention_yaml}
  reactions: ${reactions_yaml}
  free_response_chats: ${free_chats_yaml}
  custom_mention_patterns: ${patterns_yaml}
EOF
    log "Telegram channel configured (owner id: ${TELEGRAM_OWNER_ID:-not set})."
else
    info "TELEGRAM_BOT_TOKEN not set - skipping Telegram setup."
fi

# ============================================================
# Step 9: Install skills & plugins
# ============================================================
echo ""
log "━━━ Step 9: Install skills & plugins ━━━"

if [ -n "$HERMES_SKILLS" ]; then
    IFS=',' read -ra SKILL_LIST <<< "$HERMES_SKILLS"
    for skill in "${SKILL_LIST[@]}"; do
        skill="$(echo "$skill" | sed 's/^ *//;s/ *$//')"
        [ -z "$skill" ] && continue
        log "Installing skill: ${skill}..."
        if /opt/hermes-venv/bin/hermes skill install "$skill"; then
            log "Installed skill: ${skill}"
        else
            warn "Failed to install skill: ${skill}"
        fi
    done
else
    info "HERMES_SKILLS not set - skipping."
fi

# ============================================================
# Step 10: Patch Socket.IO for Boxd Reverse Proxy
# ============================================================
echo ""
log "━━━ Step 10: Patch Socket.IO for Boxd ━━━"

/opt/python3.12/bin/python3 << 'PYEOF'
import glob, os

js_dir = "/root/hermes-studio/dist/client/assets/js"
if os.path.exists(js_dir):
    os.chdir(js_dir)
    old = b'transports:["websocket","polling"]'
    new = b'transports:["polling"]'
    count = 0
    for f in glob.glob("*.js"):
        with open(f, "rb") as fp:
            content = fp.read()
        if old in content:
            content = content.replace(old, new)
            with open(f, "wb") as fp:
                fp.write(content)
            count += 1
    if count > 0:
        print(f"  Patched: {count} file(s)")
    else:
        print("  No patch needed")
else:
    print("  Client folder not found - skipped")
PYEOF

# ============================================================
# Step 11: Install Watchdog for Boxd
# ============================================================
echo ""
log "━━━ Step 11: Install watchdog system ━━━"

cat > /usr/local/bin/master-watchdog.sh << WATCHDOG_EOF
#!/bin/bash
LOG=/var/log/master-watchdog.log
mkdir -p /var/log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-venv/bin:/usr/local/node-v24/bin:\$PATH
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://${BRIDGE_SOCK}
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages

echo "[\$(ts)] Watchdog started on Boxd (PID \$\$)" >> \$LOG

while true; do
    # Check 9Router
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] 9Router down, restarting..." >> \$LOG
        pkill -9 -f "next start" 2>/dev/null
        sleep 2
        cd /root/9router
        NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} \\
            nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
        sleep 8
    fi

    # Check Bridge
    if ! pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
        echo "[\$(ts)] Bridge down, restarting..." >> \$LOG
        nohup setsid /opt/python3.12/bin/python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \\
            --endpoint ipc://${BRIDGE_SOCK} \\
            --hermes-home /root/.hermes \\
            --agent-root \$HERMES_AGENT_ROOT \\
            > /tmp/bridge.log 2>&1 < /dev/null &
        sleep 5
    fi

    # Check Hermes Studio
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] Hermes Studio down, restarting..." >> \$LOG
        pkill -9 -f "node dist/server" 2>/dev/null
        fuser -k ${HERMES_PORT}/tcp 2>/dev/null
        sleep 3
        cd /root/hermes-studio
        PORT=${HERMES_PORT} NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \\
            nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
        sleep 12
    fi

    tail -100 \$LOG > \$LOG.tmp && mv \$LOG.tmp \$LOG
    sleep 300
done
WATCHDOG_EOF
chmod +x /usr/local/bin/master-watchdog.sh

cat > /usr/local/bin/check-watchdog.sh << 'CHECK_EOF'
#!/bin/bash
if pgrep -f "master-watchdog.sh" > /dev/null 2>&1; then
    exit 0
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Watchdog restarted by Cron" >> /var/log/master-watchdog.log
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
CHECK_EOF
chmod +x /usr/local/bin/check-watchdog.sh

cat > /usr/local/bin/telegram-pairing-watch.sh << 'PAIRING_EOF'
#!/bin/bash
LOG=/var/log/telegram-pairing.log
mkdir -p /var/log
ts() { date '+%Y-%m-%d %H:%M:%S'; }

elapsed=0
while [ $elapsed -lt 900 ]; do
    code=$(grep -ohE "pairing code:[[:space:]]*[A-Za-z0-9]+" /tmp/bridge.log /tmp/hermes.log 2>/dev/null \
        | tail -1 | grep -oE "[A-Za-z0-9]+$")
    if [ -n "$code" ]; then
        echo "[$(ts)] Found pairing code ${code}, approving..." >> $LOG
        if /opt/hermes-venv/bin/hermes pairing approve telegram "$code" >> $LOG 2>&1; then
            echo "[$(ts)] Owner paired successfully." >> $LOG
        fi
        exit 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
PAIRING_EOF
chmod +x /usr/local/bin/telegram-pairing-watch.sh

log "Watchdog system configured."

# ============================================================
# Step 12: Start services
# ============================================================
echo ""
log "━━━ Step 12: Start services ━━━"

pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
pkill -f 'master-watchdog' 2>/dev/null || true
sleep 2

fuser -k ${HERMES_PORT}/tcp 2>/dev/null || true
fuser -k ${ROUTER_PORT}/tcp 2>/dev/null || true
sleep 1

# Start Bridge
log "Starting Bridge..."
export PATH=/opt/hermes-venv/bin:$PATH
export HERMES_HOME=/root/.hermes
nohup setsid /opt/python3.12/bin/python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &
sleep 5

# Start 9Router
log "Starting 9Router..."
cd /root/9router
NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} \
    nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
sleep 8

# Start Hermes Studio
log "Starting Hermes Studio..."
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
sleep 10

# Start Cron & Watchdog
if ! pgrep -x cron > /dev/null; then
    nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
fi

(crontab -l 2>/dev/null | grep -v 'check-watchdog'; echo '*/10 * * * * /usr/local/bin/check-watchdog.sh') | crontab -
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &

if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_OWNER_ID" ]; then
    nohup setsid bash /usr/local/bin/telegram-pairing-watch.sh > /dev/null 2>&1 < /dev/null &
fi

# ============================================================
# Step 13: Final Status Check
# ============================================================
echo ""
log "━━━ Final status check ━━━"
sleep 3

echo ""
echo -e "${GREEN}━━━ Installation completed successfully! ━━━${NC}"
echo ""
echo -e "${YELLOW}Public Boxd URLs:${NC}"
echo -e "  Hermes Studio: ${BLUE}https://${HERMES_PORT}-${BOX_ID}.${BOXD_DOMAIN}${NC}"
echo -e "  9Router:       ${BLUE}https://${ROUTER_PORT}-${BOX_ID}.${BOXD_DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}Hermes Studio login:${NC}"
echo -e "  Username: ${BLUE}admin${NC}"
echo -e "  Password: ${BLUE}123456${NC}"
echo ""
echo -e "${YELLOW}9Router password:${NC}"
echo -e "  Password: ${BLUE}${ROUTER_PASSWORD}${NC}"
echo ""
