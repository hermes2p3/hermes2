#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Automated installer for Daytona
# ============================================================
#  Version: 1.0
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
#  Optional environment variables (set before running to auto-configure
#  the Telegram channel and pre-install skills; all are optional and
#  can also be filled in later from the Hermes Studio "channels" tab):
#    TELEGRAM_BOT_TOKEN         Bot token from https://t.me/BotFather
#    TELEGRAM_OWNER_ID          Your numeric Telegram user ID. The owner
#                               is auto-approved for the first pairing
#                               request so you don't have to run the
#                               `hermes pairing approve` command by hand.
#    TELEGRAM_PROXY_URL         Optional proxy (http://, https://, socks5://)
#    TELEGRAM_REQUIRE_MENTION   true/false - require @mention in groups
#    TELEGRAM_REACTIONS         true/false - react to messages with emoji
#    TELEGRAM_FREE_CHATS        Comma-separated chat IDs that don't need @mention
#    TELEGRAM_MENTION_PATTERNS  Comma-separated extra trigger patterns
#    HERMES_SKILLS              Comma-separated skill/plugin sources to
#                               install, e.g. a GitHub repo per entry
#
#  Example:
#    TELEGRAM_BOT_TOKEN="123:ABC" TELEGRAM_OWNER_ID="5839201773" \
#    HERMES_SKILLS="github.com/hermes-skills/web-search" bash install.sh
#
#  After installation, the following URLs will be available:
#    - Hermes Studio: https://6060-<SANDBOX_ID>.proxy.daytona.work
#    - 9Router:       https://20127-<SANDBOX_ID>.proxy.daytona.work
#
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

# Run a command and give a clear error message on failure
run() { "$@" || error "Command failed: $*"; }

# --- Variables ---
PYTHON_VERSION="3.12.13"
PYTHON_BUILD_DATE="20260623"
NODE_VERSION="24.15.0"
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock
NODE_BUILD_OPTS="--max-old-space-size=8192"

# --- Telegram channel (all optional, see header for env vars) ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_OWNER_ID="${TELEGRAM_OWNER_ID:-}"
TELEGRAM_PROXY_URL="${TELEGRAM_PROXY_URL:-}"
TELEGRAM_REQUIRE_MENTION="${TELEGRAM_REQUIRE_MENTION:-false}"
TELEGRAM_REACTIONS="${TELEGRAM_REACTIONS:-true}"
TELEGRAM_FREE_CHATS="${TELEGRAM_FREE_CHATS:-}"
TELEGRAM_MENTION_PATTERNS="${TELEGRAM_MENTION_PATTERNS:-}"

# --- Skills & plugins to pre-install (comma-separated) ---
HERMES_SKILLS="${HERMES_SKILLS:-}"

# --- Banner ---
echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║   Hermes Studio + 9Router Installer               ║"
echo "  ║   for Daytona Sandbox                             ║"
echo "  ║                                                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    warn "Script is not running as root. Continuing anyway..."
fi

# --- Daytona environment check ---
if [ ! -f /.dockerenv ] && [ -z "${DAYTONA_SANDBOX_ID:-}" ]; then
    warn "This does not appear to be a Daytona environment. Continuing, but issues may occur."
fi

SANDBOX_ID=${DAYTONA_SANDBOX_ID:-$(hostname)}
info "Sandbox ID: ${SANDBOX_ID}"

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
# Step 3: Install hermes-agent
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

# Install system tools (only if missing, to avoid an unconditional apt run every time)
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

    log "Installing dependencies (this may take a few minutes)..."
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

# Generate all random secrets in a single Python invocation (avoids 4 separate process spawns)
read -r ROUTER_PASSWORD JWT_SECRET API_KEY_SECRET MACHINE_ID_SALT < <(python3 -c "
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

# Create config only if it doesn't already exist
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

    # bool env values -> yaml booleans, comma lists -> yaml flow lists
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

    if [ -z "$TELEGRAM_OWNER_ID" ]; then
        warn "TELEGRAM_OWNER_ID not set - pairing requests will need manual approval via 'hermes pairing approve telegram <code>'."
    fi
else
    info "TELEGRAM_BOT_TOKEN not set - skipping Telegram channel setup. You can configure it later from the Hermes Studio channels tab."
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
            warn "Failed to install skill: ${skill} - continuing."
        fi
    done
else
    info "HERMES_SKILLS not set - no skills to pre-install. Install later with: hermes skill install <source>"
fi

# ============================================================
# Step 10: Patch Socket.IO for Daytona
# ============================================================
echo ""
log "━━━ Step 10: Patch Socket.IO for Daytona ━━━"

# Replace transports:["websocket","polling"] with transports:["polling"]
# to avoid WebSocket errors behind the Daytona proxy
python3 << 'PYEOF'
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
# Step 11: Install watchdog scripts
# ============================================================
echo ""
log "━━━ Step 11: Install watchdog system ━━━"

# --- Main watchdog script ---
cat > /usr/local/bin/master-watchdog.sh << WATCHDOG_EOF
#!/bin/bash
# Self-healing watchdog - checks services every 5 minutes

LOG=/var/log/master-watchdog.log
mkdir -p /var/log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-venv/bin:/usr/local/node-v24/bin:\$PATH
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://${BRIDGE_SOCK}
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages

echo "[\$(ts)] Watchdog started (PID \$\$)" >> \$LOG

while true; do
    # --- Check 9Router ---
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] 9Router is down, restarting..." >> \$LOG
        pkill -9 -f "next start" 2>/dev/null
        sleep 2
        cd /root/9router
        NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} \\
            nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
        sleep 8
    fi

    # --- Check Bridge ---
    if ! pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
        echo "[\$(ts)] Bridge is down, restarting..." >> \$LOG
        nohup setsid python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \\
            --endpoint ipc://${BRIDGE_SOCK} \\
            --hermes-home /root/.hermes \\
            --agent-root \$HERMES_AGENT_ROOT \\
            > /tmp/bridge.log 2>&1 < /dev/null &
        sleep 5
    fi

    # --- Check Hermes Studio ---
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] Hermes Studio is down, restarting..." >> \$LOG
        pkill -9 -f "node dist/server" 2>/dev/null
        fuser -k ${HERMES_PORT}/tcp 2>/dev/null
        sleep 3
        cd /root/hermes-studio
        PORT=${HERMES_PORT} NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \\
            nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
        sleep 12
    fi

    # --- Check Cron ---
    if ! pgrep -x cron > /dev/null 2>&1; then
        echo "[\$(ts)] Cron is down, restarting..." >> \$LOG
        nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
        sleep 2
    fi

    # --- Heartbeat (prevents sandbox auto-stop) ---
    echo "[\$(ts)] Tick - all services healthy" >> \$LOG

    # Keep the log file small
    tail -100 \$LOG > \$LOG.tmp && mv \$LOG.tmp \$LOG

    sleep 300  # 5 minutes
done
WATCHDOG_EOF
chmod +x /usr/local/bin/master-watchdog.sh

# --- Watchdog liveness check for cron ---
cat > /usr/local/bin/check-watchdog.sh << 'CHECK_EOF'
#!/bin/bash
# Checks whether the watchdog is alive - run every 10 minutes by cron

if pgrep -f "master-watchdog.sh" > /dev/null 2>&1; then
    exit 0
fi

# Watchdog is dead - restart it
echo "$(date '+%Y-%m-%d %H:%M:%S') Cron: watchdog was dead, restarting..." >> /var/log/master-watchdog.log
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
CHECK_EOF
chmod +x /usr/local/bin/check-watchdog.sh

# --- Telegram pairing auto-approve (owner only, one-time) ---
# Watches the bridge/hermes logs for the "Here's your pairing code: XXXX"
# message and automatically runs `hermes pairing approve telegram XXXX`
# so the owner doesn't have to copy/paste it into the console by hand.
# Only runs when TELEGRAM_OWNER_ID was provided, and only approves the
# FIRST code it sees (the owner's own initial pairing) - later pairing
# requests from other users still require manual review, for safety.
cat > /usr/local/bin/telegram-pairing-watch.sh << 'PAIRING_EOF'
#!/bin/bash
LOG=/var/log/telegram-pairing.log
mkdir -p /var/log
ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(ts)] Watching for the owner's first Telegram pairing code..." >> $LOG

elapsed=0
while [ $elapsed -lt 900 ]; do
    code=$(grep -ohE "pairing code:[[:space:]]*[A-Za-z0-9]+" /tmp/bridge.log /tmp/hermes.log 2>/dev/null \
        | tail -1 | grep -oE "[A-Za-z0-9]+$")
    if [ -n "$code" ]; then
        echo "[$(ts)] Found pairing code ${code}, approving as owner..." >> $LOG
        if /opt/hermes-venv/bin/hermes pairing approve telegram "$code" >> $LOG 2>&1; then
            echo "[$(ts)] ✓ hermes pairing approve telegram ${code} - owner paired." >> $LOG
        else
            echo "[$(ts)] ✗ Approval command failed, please run it manually: hermes pairing approve telegram ${code}" >> $LOG
        fi
        exit 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
echo "[$(ts)] No pairing code seen within 15 minutes - stopping watcher. Message the bot to retry, then approve manually if needed." >> $LOG
PAIRING_EOF
chmod +x /usr/local/bin/telegram-pairing-watch.sh

log "Watchdog scripts installed."

# ============================================================
# Step 12: Start services
# ============================================================
echo ""
log "━━━ Step 12: Start services ━━━"

# Stop any previous instances
pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
pkill -f 'master-watchdog' 2>/dev/null || true
sleep 3

# Free up ports
fuser -k ${HERMES_PORT}/tcp 2>/dev/null || true
fuser -k ${ROUTER_PORT}/tcp 2>/dev/null || true
sleep 2

# --- Start Bridge ---
log "Starting Bridge..."
export PATH=/opt/hermes-venv/bin:$PATH
export HERMES_HOME=/root/.hermes
nohup setsid python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &
sleep 5

# --- Start 9Router ---
log "Starting 9Router..."
cd /root/9router
NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} \
    nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
sleep 8

# --- Start Hermes Studio ---
log "Starting Hermes Studio..."
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
sleep 12

# --- Start Cron ---
log "Starting Cron..."
if ! pgrep -x cron > /dev/null; then
    nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
    sleep 2
fi

# --- Set up crontab ---
(crontab -l 2>/dev/null | grep -v 'check-watchdog'; echo '*/10 * * * * /usr/local/bin/check-watchdog.sh') | crontab -
log "Cron configured: watchdog checked every 10 minutes."

# --- Start Watchdog ---
log "Starting watchdog system..."
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
sleep 3

# --- Start Telegram pairing watcher (owner-only, one-time) ---
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_OWNER_ID" ]; then
    log "Starting Telegram pairing watcher (auto-approves your first pairing code)..."
    pkill -f 'telegram-pairing-watch.sh' 2>/dev/null || true
    nohup setsid bash /usr/local/bin/telegram-pairing-watch.sh > /dev/null 2>&1 < /dev/null &
fi

# ============================================================
# Step 13: Final health check
# ============================================================
echo ""
log "━━━ Final health check ━━━"

sleep 5

echo ""
echo -e "${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              Service status               │${NC}"
echo -e "${CYAN}├──────────────────────────────────────────┤${NC}"

# Check 9Router
if curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} 9Router        ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} 9Router        ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

# Check Bridge
if pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Bridge         ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Bridge         ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

# Check Hermes Studio
if curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} Hermes Studio  ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Hermes Studio  ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

# Check Cron
if pgrep -x cron > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Cron           ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Cron           ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

# Check Watchdog
if pgrep -f "master-watchdog" > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Watchdog       ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Watchdog       ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

echo -e "${CYAN}└──────────────────────────────────────────┘${NC}"

echo ""
echo -e "${GREEN}━━━ Installation completed successfully! ━━━${NC}"
echo ""
echo -e "${YELLOW}Public URLs:${NC}"
echo -e "  Hermes Studio: ${BLUE}https://${HERMES_PORT}-${SANDBOX_ID}.proxy.daytona.work${NC}"
echo -e "  9Router:       ${BLUE}https://${ROUTER_PORT}-${SANDBOX_ID}.proxy.daytona.work${NC}"
echo ""
echo -e "${YELLOW}Hermes Studio login:${NC}"
echo -e "  Username: ${BLUE}admin${NC}"
echo -e "  Password: ${BLUE}123456${NC}"
echo ""
echo -e "${YELLOW}9Router login:${NC}"
echo -e "  Password: ${BLUE}${ROUTER_PASSWORD}${NC}"
echo ""
echo -e "${YELLOW}Default free AI model:${NC}"
echo -e "  ${BLUE}oc/mimo-v2.5-free${NC} (via 9Router)"
echo ""

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${YELLOW}Telegram channel:${NC}"
    echo -e "  Status:  ${GREEN}configured${NC}"
    if [ -n "$TELEGRAM_OWNER_ID" ]; then
        echo -e "  Owner:   ${BLUE}${TELEGRAM_OWNER_ID}${NC} (first pairing code will be auto-approved)"
        echo -e "  Watcher log: ${BLUE}tail -f /var/log/telegram-pairing.log${NC}"
    else
        echo -e "  Owner:   ${YELLOW}not set${NC} - message the bot, then run:"
        echo -e "           ${BLUE}hermes pairing approve telegram <code>${NC}"
    fi
    echo ""
fi

if [ -n "$HERMES_SKILLS" ]; then
    echo -e "${YELLOW}Skills installed:${NC}"
    echo -e "  ${BLUE}${HERMES_SKILLS}${NC}"
    echo -e "  Manage with: ${BLUE}hermes skill list${NC} / ${BLUE}hermes skill install <source>${NC}"
    echo ""
fi

echo -e "${YELLOW}Notes:${NC}"
echo -e "  • The watchdog checks services every 5 minutes"
echo -e "  • If a service goes down, it will be restarted automatically"
echo -e "  • To view logs: ${BLUE}tail -20 /var/log/master-watchdog.log${NC}"
echo -e "  • To start the watchdog manually: ${BLUE}bash /usr/local/bin/master-watchdog.sh &${NC}"
echo ""
