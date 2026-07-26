#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Installer for app.boxd.sh
# ============================================================
#  Version: 1.0
#  License: MIT
# ============================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }

# --- Variables ---
PYTHON_VERSION="3.12.13"
PYTHON_BUILD_DATE="20260623"
NODE_VERSION="24.15.0"
HERMES_PORT=8080
ROUTER_PORT=8081
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock
NODE_BUILD_OPTS="--max-old-space-size=8192"
DOMAIN="app.boxd.sh"

# --- Optional Telegram env vars ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_OWNER_ID="${TELEGRAM_OWNER_ID:-}"
TELEGRAM_PROXY_URL="${TELEGRAM_PROXY_URL:-}"
TELEGRAM_REQUIRE_MENTION="${TELEGRAM_REQUIRE_MENTION:-false}"
TELEGRAM_REACTIONS="${TELEGRAM_REACTIONS:-true}"
TELEGRAM_FREE_CHATS="${TELEGRAM_FREE_CHATS:-}"
TELEGRAM_MENTION_PATTERNS="${TELEGRAM_MENTION_PATTERNS:-}"
HERMES_SKILLS="${HERMES_SKILLS:-}"

# --- Banner ---
echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  Hermes Studio + 9Router                ║"
echo "  ║  Installer for app.boxd.sh              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

[ "$(id -u)" -ne 0 ] && warn "Not running as root. Continue anyway..."

# ============================================================
# Step 1: System tools
# ============================================================
log "━━━ Step 1: System tools ━━━"
apt-get update -qq && apt-get install -y -qq cron curl git make g++ python3-dev nginx certbot python3-certbot-nginx > /dev/null 2>&1 || warn "Some packages failed"
info "System tools installed."

# ============================================================
# Step 2: Node.js
# ============================================================
log "━━━ Step 2: Node.js ━━━"
if command -v node &>/dev/null && [ "$(node -v | cut -d. -f1 | tr -d v)" -ge 23 ]; then
    info "Node.js $(node -v) already installed."
else
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" -o /tmp/node.tar.gz
    mkdir -p /usr/local/node-v24
    tar -xzf /tmp/node.tar.gz -C /usr/local/node-v24 --strip-components=1
    rm -f /tmp/node.tar.gz
    ln -sf /usr/local/node-v24/bin/node /usr/local/bin/node
    ln -sf /usr/local/node-v24/bin/npm /usr/local/bin/npm
    ln -sf /usr/local/node-v24/bin/npx /usr/local/bin/npx
    log "Node.js: $(node -v)"
fi

# ============================================================
# Step 3: Python 3.12
# ============================================================
log "━━━ Step 3: Python 3.12 ━━━"
if /opt/python3.12/bin/python3 --version &>/dev/null; then
    info "Python 3.12 already installed."
else
    curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/cpython-${PYTHON_VERSION}%2B${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" -o /tmp/python.tar.gz
    mkdir -p /opt/python3.12
    tar -xzf /tmp/python.tar.gz -C /opt/python3.12 --strip-components=1
    rm -f /tmp/python.tar.gz
    log "Python: $(/opt/python3.12/bin/python3 --version)"
fi

# ============================================================
# Step 4: hermes-agent
# ============================================================
log "━━━ Step 4: hermes-agent ━━━"
if [ -f /opt/hermes-venv/bin/hermes ]; then
    info "hermes-agent already installed."
else
    rm -rf /opt/hermes-venv
    /opt/python3.12/bin/python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip -q
    /opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
    log "hermes-agent: $(/opt/hermes-venv/bin/hermes --version 2>&1 | head -1)"
fi

# ============================================================
# Step 5: Hermes Studio
# ============================================================
log "━━━ Step 5: Hermes Studio ━━━"
mkdir -p /var/www/hermes
if [ -d /var/www/hermes/studio/dist ]; then
    info "Hermes Studio already built."
else
    rm -rf /var/www/hermes/studio
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /var/www/hermes/studio
    cd /var/www/hermes/studio
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=https://${DOMAIN}:${HERMES_PORT} npm run build
    npm rebuild node-pty 2>/dev/null || true
fi

# ============================================================
# Step 6: 9Router
# ============================================================
log "━━━ Step 6: 9Router ━━━"
if [ -d /var/www/hermes/9router/.next ]; then
    info "9Router already built."
else
    rm -rf /var/www/hermes/9router
    git clone --depth 1 https://github.com/decolua/9router.git /var/www/hermes/9router
    cd /var/www/hermes/9router
    NODE_OPTIONS=$NODE_BUILD_OPTS npm install --no-audit --no-fund
    NODE_OPTIONS=$NODE_BUILD_OPTS NEXT_PUBLIC_BASE_URL=https://${DOMAIN}:${ROUTER_PORT} npm run build
fi

# ============================================================
# Step 7: Configure 9Router
# ============================================================
log "━━━ Step 7: Configure 9Router ━━━"
read -r ROUTER_PASSWORD JWT_SECRET API_KEY_SECRET MACHINE_ID_SALT < <(python3 -c "
import secrets
print(secrets.token_urlsafe(16), secrets.token_urlsafe(48), secrets.token_urlsafe(32), secrets.token_urlsafe(32))
")

cat > /var/www/hermes/9router/.env << EOF
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${ROUTER_PASSWORD}
DATA_DIR=/var/lib/9router
PORT=${ROUTER_PORT}
NODE_ENV=production
API_KEY_SECRET=${API_KEY_SECRET}
MACHINE_ID_SALT=${MACHINE_ID_SALT}
ENABLE_REQUEST_LOGS=false
OBSERVABILITY_ENABLED=false
AUTH_COOKIE_SECURE=true
REQUIRE_API_KEY=false
BASE_URL=https://${DOMAIN}:${ROUTER_PORT}
CLOUD_URL=https://9router.com
NEXT_PUBLIC_BASE_URL=https://${DOMAIN}:${ROUTER_PORT}
NEXT_PUBLIC_CLOUD_URL=https://9router.com
HOSTNAME=0.0.0.0
EOF
log "9Router password: ${ROUTER_PASSWORD}"

# ============================================================
# Step 8: Configure Hermes
# ============================================================
log "━━━ Step 8: Configure Hermes ━━━"
mkdir -p /root/.hermes /root/.hermes-web-ui

if [ ! -f /root/.hermes/config.yaml ]; then
    cat > /root/.hermes/config.yaml << EOF
model:
  default: oc/mimo-v2.5-free
  provider: custom:local-router
custom_providers:
  - name: local-router
    base_url: http://127.0.0.1:${ROUTER_PORT}/v1
    api_key: ''
    model: oc/mimo-v2.5-free
    api_mode: chat_completions
    models:
      oc/mimo-v2.5-free:
        context_length: 1000000
EOF
fi

# ============================================================
# Step 9: Telegram (optional)
# ============================================================
log "━━━ Step 9: Telegram ━━━"
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    mkdir -p /root/.hermes/channels
    require_mention_yaml="false"; [ "$TELEGRAM_REQUIRE_MENTION" = "true" ] && require_mention_yaml="true"
    reactions_yaml="true"; [ "$TELEGRAM_REACTIONS" = "false" ] && reactions_yaml="false"
    free_chats_yaml="[]"
    [ -n "$TELEGRAM_FREE_CHATS" ] && free_chats_yaml="[$(echo "$TELEGRAM_FREE_CHATS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | paste -sd, -)]"
    patterns_yaml="[]"
    [ -n "$TELEGRAM_MENTION_PATTERNS" ] && patterns_yaml="[$(echo "$TELEGRAM_MENTION_PATTERNS" | tr ',' '\n' | sed 's/^ *//;s/ *$//;s/.*/"&"/' | paste -sd, -)]"

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
    log "Telegram configured."
fi

# ============================================================
# Step 10: Skills
# ============================================================
log "━━━ Step 10: Skills ━━━"
if [ -n "$HERMES_SKILLS" ]; then
    IFS=',' read -ra SKILL_LIST <<< "$HERMES_SKILLS"
    for skill in "${SKILL_LIST[@]}"; do
        skill="$(echo "$skill" | sed 's/^ *//;s/ *$//')"
        [ -z "$skill" ] && continue
        /opt/hermes-venv/bin/hermes skill install "$skill" || warn "Failed: $skill"
    done
fi

# ============================================================
# Step 11: Watchdog
# ============================================================
log "━━━ Step 11: Watchdog ━━━"

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

echo "[\$(ts)] Watchdog started (PID \$\$)" >> \$LOG

while true; do
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] 9Router down, restarting..." >> \$LOG
        pkill -9 -f "next start" 2>/dev/null
        sleep 2
        cd /var/www/hermes/9router
        nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
        sleep 8
    fi
    if ! pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
        echo "[\$(ts)] Bridge down, restarting..." >> \$LOG
        nohup setsid python3 /var/www/hermes/studio/dist/server/agent-bridge/python/hermes_bridge.py \\
            --endpoint ipc://${BRIDGE_SOCK} --hermes-home /root/.hermes \\
            --agent-root \$HERMES_AGENT_ROOT > /tmp/bridge.log 2>&1 < /dev/null &
        sleep 5
    fi
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
        echo "[\$(ts)] Studio down, restarting..." >> \$LOG
        pkill -9 -f "node dist/server" 2>/dev/null
        fuser -k ${HERMES_PORT}/tcp 2>/dev/null
        sleep 3
        cd /var/www/hermes/studio
        PORT=${HERMES_PORT} NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \\
            nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
        sleep 12
    fi
    if ! pgrep -x cron > /dev/null 2>&1; then
        nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
        sleep 2
    fi
    echo "[\$(ts)] Tick" >> \$LOG
    tail -100 \$LOG > \$LOG.tmp && mv \$LOG.tmp \$LOG
    sleep 300
done
WATCHDOG_EOF
chmod +x /usr/local/bin/master-watchdog.sh

cat > /usr/local/bin/check-watchdog.sh << 'CHECK_EOF'
#!/bin/bash
pgrep -f "master-watchdog.sh" > /dev/null 2>&1 && exit 0
echo "$(date) Cron: restarting watchdog..." >> /var/log/master-watchdog.log
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
CHECK_EOF
chmod +x /usr/local/bin/check-watchdog.sh

# ============================================================
# Step 12: Nginx config
# ============================================================
log "━━━ Step 12: Nginx ━━━"

cat > /etc/nginx/sites-available/hermes << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /studio {
        proxy_pass http://127.0.0.1:${HERMES_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location /9router {
        proxy_pass http://127.0.0.1:${ROUTER_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
EOF

ln -sf /etc/nginx/sites-available/hermes /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# SSL
log "Setting up SSL..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN} || warn "SSL setup skipped"

# ============================================================
# Step 13: Start services
# ============================================================
log "━━━ Step 13: Start services ━━━"

pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
pkill -f 'master-watchdog' 2>/dev/null || true
sleep 3
fuser -k ${HERMES_PORT}/tcp 2>/dev/null || true
fuser -k ${ROUTER_PORT}/tcp 2>/dev/null || true
sleep 2

# Bridge
log "Starting Bridge..."
export PATH=/opt/hermes-venv/bin:$PATH
export HERMES_HOME=/root/.hermes
nohup setsid python3 /var/www/hermes/studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &
sleep 5

# 9Router
log "Starting 9Router..."
cd /var/www/hermes/9router
nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
sleep 8

# Hermes Studio
log "Starting Hermes Studio..."
cd /var/www/hermes/studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
sleep 12

# Cron
log "Starting Cron..."
nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
sleep 2
(crontab -l 2>/dev/null | grep -v 'check-watchdog'; echo '*/10 * * * * /usr/local/bin/check-watchdog.sh') | crontab -

# Watchdog
log "Starting Watchdog..."
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
sleep 3

# ============================================================
# Final
# ============================================================
echo ""
echo -e "${GREEN}━━━ Installation Complete! ━━━${NC}"
echo ""
echo -e "  Hermes Studio: ${BLUE}https://${DOMAIN}/studio${NC}"
echo -e "  9Router:       ${BLUE}https://${DOMAIN}/9router${NC}"
echo ""
echo -e "  Studio login:  admin / 123456"
echo -e "  Router pass:   ${ROUTER_PASSWORD}"
echo ""
