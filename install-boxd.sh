#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - Automated installer for boxd.sh
# ============================================================
#  Version: 1.0 (boxd-native)
#  License: MIT
# ============================================================
#
#  This is the boxd.sh port of the Daytona installer. It uses the
#  real boxd platform primitives (per https://docs.boxd.sh), which
#  differ from Daytona in a few important ways:
#
#   - You land on a boxd VM as the `boxd` user with passwordless
#     sudo, NOT as root. This script re-execs itself with `sudo -E`
#     so every later step behaves like the original (root, $HOME
#     resolving to /root, etc).
#   - There is no $DAYTONA_SANDBOX_ID. Machine identity comes from
#     `boxd info --json` (falls back to `hostname` if the boxd CLI
#     isn't present, e.g. when testing outside a real boxd VM).
#   - There is no proxy-URL-with-port-in-the-hostname scheme. A
#     boxd VM gets exactly one default HTTPS proxy for one port
#     (https://<name>.boxd.sh -> :8000 by default). Extra ports need
#     an explicit subdomain proxy via `boxd machine proxy new`. This
#     script points the *default* proxy at Hermes Studio and adds a
#     "router" subdomain proxy for 9Router.
#   - The boxd default image already ships curl, wget, git,
#     build-essential, Node 24 (via nvm, only wired into
#     *interactive* shells), and a Python 3.12 system interpreter.
#     This script detects and reuses those instead of re-downloading
#     them, and only falls back to the original download-based
#     install if something is missing.
#   - The `boxd` CLI itself is pre-installed and pre-authenticated
#     by source IP on every boxd VM - no API key or login step is
#     needed to call `boxd machine proxy ...` from inside the box.
#
#  Usage (from an SSH session on a boxd VM, e.g. `ssh myapp.boxd`):
#    bash install.sh
#
#  Optional environment variables (same as the Daytona version; set
#  before running to auto-configure the Telegram channel and
#  pre-install skills non-interactively; if TELEGRAM_BOT_TOKEN is not
#  set and the script is running in an interactive terminal, it will
#  ask you instead):
#    TELEGRAM_BOT_TOKEN, TELEGRAM_OWNER_ID, TELEGRAM_PROXY_URL,
#    TELEGRAM_REQUIRE_MENTION, TELEGRAM_REACTIONS, TELEGRAM_FREE_CHATS,
#    TELEGRAM_MENTION_PATTERNS, SKIP_TELEGRAM_PROMPT, HERMES_SKILLS
#
#  After installation, the following URLs will be available:
#    - Hermes Studio: https://<machine-name>.boxd.sh
#    - 9Router:       https://router.<machine-name>.boxd.sh
#
# ============================================================

set -euo pipefail

# --- Re-exec as root via sudo, preserving env vars ---
# boxd VMs land you on as the `boxd` user (passwordless sudo), not
# root. Everything below assumes root (writes to /opt, /root,
# /usr/local/bin, runs apt-get). `-E` keeps TELEGRAM_*/HERMES_SKILLS/
# SKIP_TELEGRAM_PROMPT that the caller exported. sudo still resets
# $HOME to /root for the elevated process, matching what the rest of
# this script (and the original Daytona version) expects.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

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

# Read a line from the real terminal even when the script itself is
# being fed via a pipe (e.g. `curl ... | sudo bash`), so interactive
# prompts still work. Falls back silently (empty answer) if there is
# no terminal attached at all.
ask() {
    local prompt="$1" __resultvar="$2" default="${3:-}" answer=""
    if [ -r /dev/tty ]; then
        # shellcheck disable=SC2162
        read -r -p "$prompt" answer < /dev/tty || answer=""
    fi
    [ -z "$answer" ] && answer="$default"
    printf -v "$__resultvar" '%s' "$answer"
}

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
SKIP_TELEGRAM_PROMPT="${SKIP_TELEGRAM_PROMPT:-false}"

# --- Skills & plugins to pre-install (comma-separated) ---
HERMES_SKILLS="${HERMES_SKILLS:-}"

# --- Banner ---
echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║   Hermes Studio + 9Router Installer               ║"
echo "  ║   for boxd.sh                                     ║"
echo "  ║                                                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# --- boxd platform check ---
# The `boxd` CLI ships pre-installed and pre-authenticated (by source
# IP) on every real boxd VM - see docs.boxd.sh/reference/internal-cli.
# If it's missing we're probably not actually on boxd; warn but keep
# going so the script is still useful for local testing, just skip
# the proxy-wiring steps later.
HAVE_BOXD_CLI=false
if command -v boxd &>/dev/null; then
    HAVE_BOXD_CLI=true
    info "boxd CLI detected."
else
    warn "The 'boxd' CLI was not found - this doesn't look like a real boxd VM. Continuing, but the automatic proxy setup (Step 13) will be skipped."
fi

# --- Machine identity ---
# There's no \$DAYTONA_SANDBOX_ID equivalent; the closest thing is the
# machine's own name, retrievable in-VM with `boxd info --json`
# (docs.boxd.sh/reference/internal-cli). Falls back to hostname.
MACHINE_NAME=""
if [ "$HAVE_BOXD_CLI" = true ]; then
    MACHINE_NAME=$(boxd info --json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)
fi
[ -z "$MACHINE_NAME" ] && MACHINE_NAME=$(hostname)
info "Machine name: ${MACHINE_NAME}"

# ============================================================
# Step 0: Install system prerequisites
# ============================================================
echo ""
log "━━━ Step 0: Install system prerequisites ━━━"

# The default boxd image (Ubuntu 24.04, unminimized) already ships
# curl, wget, git, build-essential (gcc/g++/make), jq, unzip, tar and
# gzip - see docs.boxd.sh/how-it-works/vms "What's inside". cron and
# psmisc (fuser) are NOT in that list, so they're the ones most
# likely to actually need installing here. We still check the full
# set instead of assuming, since custom images can differ.
REQUIRED_PKGS=(
    ca-certificates
    curl
    wget
    git
    make
    g++
    python3-dev
    cron
    psmisc     # provides fuser, used by the watchdog
    procps     # provides pgrep/pkill
    tar
    gzip
    unzip
    gnupg
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    log "Installing missing prerequisites: ${MISSING_PKGS[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING_PKGS[@]}" > /dev/null \
        || error "Failed to install prerequisites: ${MISSING_PKGS[*]}"
    log "Prerequisites installed."
else
    info "All system prerequisites are already installed (boxd's default image covers most of these)."
fi

command -v curl &>/dev/null || error "curl is still missing after installation attempt - aborting."

# ============================================================
# Step 1: Install Node.js
# ============================================================
echo ""
log "━━━ Step 1: Install Node.js ━━━"

# boxd's default image already has Node 24, installed via nvm for the
# `boxd` user - but nvm only wires itself into *interactive* shells
# (SSH, `boxd connect`), so a root/non-interactive context like this
# script won't see it on PATH by default (docs.boxd.sh/how-it-works/vms).
# Try to pick up that pre-installed copy first, then fall back to the
# original standalone download so the script still works on non-boxd
# hosts or minimal images.
node_found=false

if command -v node &>/dev/null && [ "$(node -v | cut -d. -f1 | tr -d v)" -ge 23 ]; then
    node_found=true
    info "Node.js $(node -v) is already on PATH."
else
    # Look for nvm's Node under every home directory (covers the
    # `boxd` user even though we're running as root right now).
    for nvm_node in /home/*/.nvm/versions/node/*/bin/node /root/.nvm/versions/node/*/bin/node; do
        [ -x "$nvm_node" ] || continue
        node_bin_dir="$(dirname "$nvm_node")"
        found_version="$("$nvm_node" -v | cut -d. -f1 | tr -d v)"
        if [ "$found_version" -ge 23 ]; then
            ln -sf "$node_bin_dir/node" /usr/local/bin/node
            ln -sf "$node_bin_dir/npm" /usr/local/bin/npm
            ln -sf "$node_bin_dir/npx" /usr/local/bin/npx
            node_found=true
            info "Found boxd's pre-installed Node.js $(node -v) via nvm - linked into /usr/local/bin."
            break
        fi
    done
fi

if [ "$node_found" = false ]; then
    log "No usable Node.js found - downloading Node.js v${NODE_VERSION}..."
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

# Ubuntu 24.04 (boxd's default image) ships python3.12 as the system
# interpreter out of the box. Reuse it via a stable /opt/python3.12
# path so the rest of the script (which expects that path) doesn't
# need to change, and only download the standalone build if the
# system doesn't actually have 3.12 (e.g. a custom/older image).
if /opt/python3.12/bin/python3 --version &>/dev/null; then
    info "Python 3.12 is already installed at /opt/python3.12."
elif command -v python3.12 &>/dev/null; then
    log "Using boxd's pre-installed system Python 3.12..."
    mkdir -p /opt/python3.12/bin
    ln -sf "$(command -v python3.12)" /opt/python3.12/bin/python3
    # venv module needs to resolve relative to the real interpreter,
    # so keep this a symlink rather than a copy.
    log "Linked system Python: $(/opt/python3.12/bin/python3 --version)"
else
    log "No system Python 3.12 found - downloading Python ${PYTHON_VERSION}..."
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

if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ "$SKIP_TELEGRAM_PROMPT" != "true" ] && [ -r /dev/tty ]; then
    setup_choice=""
    ask "Configure a Telegram channel now? [y/N]: " setup_choice "n"
    case "$setup_choice" in
        y|Y|yes|YES)
            ask "Telegram bot token (from @BotFather): " TELEGRAM_BOT_TOKEN ""
            if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
                ask "Your numeric Telegram user ID (owner, optional but recommended): " TELEGRAM_OWNER_ID ""
                ask "Proxy URL (optional, press Enter to skip): " TELEGRAM_PROXY_URL ""
                ask "Require @mention in group chats? [y/N]: " require_answer "n"
                case "$require_answer" in y|Y|yes|YES) TELEGRAM_REQUIRE_MENTION="true";; *) TELEGRAM_REQUIRE_MENTION="false";; esac
                ask "Enable emoji reactions? [Y/n]: " reactions_answer "y"
                case "$reactions_answer" in n|N|no|NO) TELEGRAM_REACTIONS="false";; *) TELEGRAM_REACTIONS="true";; esac
            else
                warn "No token entered - skipping Telegram setup."
            fi
            ;;
        *)
            info "Skipping interactive Telegram setup."
            ;;
    esac
elif [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    info "No TELEGRAM_BOT_TOKEN and no interactive terminal available - skipping Telegram prompt."
fi

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

    if [ -z "$TELEGRAM_OWNER_ID" ]; then
        warn "TELEGRAM_OWNER_ID not set - pairing requests will need manual approval via 'hermes pairing approve telegram <code>'."
    fi
else
    info "Telegram channel not configured. You can set it up later from the Hermes Studio channels tab, or re-run with TELEGRAM_BOT_TOKEN set."
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
# Step 10: Patch Socket.IO for boxd's HTTPS proxy
# ============================================================
echo ""
log "━━━ Step 10: Patch Socket.IO for the proxy ━━━"

# boxd's HTTPS proxy supports WebSockets natively
# (docs.boxd.sh/cloud-dev-boxes/live-demos: "The proxy upgrades
# WebSocket connections transparently"), so this patch is not
# strictly required the way it was on Daytona. It's kept anyway as a
# harmless, defensive fallback to plain long-polling in case a given
# proxy hop or corporate network in front of the user blocks
# WebSocket upgrades.
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

cat > /usr/local/bin/master-watchdog.sh << WATCHDOG_EOF
#!/bin/bash
# Self-healing watchdog - checks services every 5 minutes

LOG=/var/log/master-watchdog.log
mkdir -p /var/log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-venv/bin:/usr/local/bin:\$PATH
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

    # --- Heartbeat ---
    # NOTE: on boxd this heartbeat does NOT prevent the VM from
    # suspending/hibernating the way it did on Daytona - boxd's idle
    # timers watch *inbound network traffic*, not CPU or background
    # processes (docs.boxd.sh/how-it-works/suspend-resume). A cron-
    # driven loop like this one can itself go quiet mid-tick if the
    # VM hibernates. That's fine for a bot that only needs to respond
    # to inbound Telegram/webhook traffic (which wakes the VM), but if
    # you need this watchdog to keep ticking in the background with
    # zero inbound traffic, disable auto-hibernate on this machine:
    #   boxd machine config set <name> auto-hibernate.timeout 0
    echo "[\$(ts)] Tick - all services healthy" >> \$LOG

    tail -100 \$LOG > \$LOG.tmp && mv \$LOG.tmp \$LOG

    sleep 300  # 5 minutes
done
WATCHDOG_EOF
chmod +x /usr/local/bin/master-watchdog.sh

cat > /usr/local/bin/check-watchdog.sh << 'CHECK_EOF'
#!/bin/bash
# Checks whether the watchdog is alive - run every 10 minutes by cron

if pgrep -f "master-watchdog.sh" > /dev/null 2>&1; then
    exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') Cron: watchdog was dead, restarting..." >> /var/log/master-watchdog.log
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
CHECK_EOF
chmod +x /usr/local/bin/check-watchdog.sh

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

pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
pkill -f 'master-watchdog' 2>/dev/null || true
sleep 3

fuser -k ${HERMES_PORT}/tcp 2>/dev/null || true
fuser -k ${ROUTER_PORT}/tcp 2>/dev/null || true
sleep 2

log "Starting Bridge..."
export PATH=/opt/hermes-venv/bin:$PATH
export HERMES_HOME=/root/.hermes
nohup setsid python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &
sleep 5

log "Starting 9Router..."
cd /root/9router
NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} \
    nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
sleep 8

log "Starting Hermes Studio..."
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
sleep 12

log "Starting Cron..."
if ! pgrep -x cron > /dev/null; then
    nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
    sleep 2
fi

# --- Set up crontab ---
# Same fix as the Daytona version: with `set -e`/`pipefail` active,
# `crontab -l` exits non-zero the first time (no crontab exists yet
# for root) and, piped straight into `grep -v` with no input, `grep`
# also exits 1 - which used to abort this whole statement before the
# `echo` line ran, silently leaving the watchdog cron job never
# installed. `|| true` stops `set -e` from aborting the pipeline.
{ crontab -l 2>/dev/null | grep -v 'check-watchdog' || true; \
  echo '*/10 * * * * /usr/local/bin/check-watchdog.sh'; } | crontab -
log "Cron configured: watchdog checked every 10 minutes."

log "Starting watchdog system..."
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
sleep 3

if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_OWNER_ID" ]; then
    log "Starting Telegram pairing watcher (auto-approves your first pairing code)..."
    pkill -f 'telegram-pairing-watch.sh' 2>/dev/null || true
    nohup setsid bash /usr/local/bin/telegram-pairing-watch.sh > /dev/null 2>&1 < /dev/null &
fi

# ============================================================
# Step 13: Wire up boxd HTTPS proxies
# ============================================================
echo ""
log "━━━ Step 13: Configure boxd proxies ━━━"

# boxd gives every VM exactly one default proxy (name.boxd.sh -> :8000
# out of the box). We repoint that default proxy at Hermes Studio's
# port and add a "router" subdomain proxy for 9Router.
# See docs.boxd.sh/how-it-works/proxies and
# docs.boxd.sh/reference/internal-cli ("Proxy management").
if [ "$HAVE_BOXD_CLI" = true ]; then
    if boxd machine proxy set-port --port "${HERMES_PORT}" &>/tmp/boxd-proxy-hermes.log; then
        log "Default proxy now points at Hermes Studio (port ${HERMES_PORT})."
    else
        warn "Could not set the default proxy port:"
        sed 's/^/    /' /tmp/boxd-proxy-hermes.log
    fi

    # NOTE: the real subcommand is `new`, not `add` - `boxd machine
    # proxy --help` on the actual installed binary is the source of
    # truth here (confirmed against a live boxd VM), overriding an
    # earlier/inconsistent doc snippet that showed `add`.
    if boxd machine proxy new router --port "${ROUTER_PORT}" &>/tmp/boxd-proxy-router.log; then
        log "Added subdomain proxy 'router' for 9Router (port ${ROUTER_PORT})."
    elif grep -qi 'already exists' /tmp/boxd-proxy-router.log; then
        info "Proxy 'router' already exists from a previous run - leaving it as is."
    else
        warn "Could not create the 'router' proxy:"
        sed 's/^/    /' /tmp/boxd-proxy-router.log
    fi
else
    warn "Skipping proxy setup - boxd CLI not available. Expose the ports manually with 'boxd machine proxy set-port' / 'boxd machine proxy new' once you're on a real boxd VM."
fi

# ============================================================
# Step 14: Final health check
# ============================================================
echo ""
log "━━━ Final health check ━━━"

sleep 5

echo ""
echo -e "${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│              Service status               │${NC}"
echo -e "${CYAN}├──────────────────────────────────────────┤${NC}"

if curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} 9Router        ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} 9Router        ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

if pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Bridge         ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Bridge         ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

if curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} Hermes Studio  ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Hermes Studio  ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

if pgrep -x cron > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Cron           ${GREEN}✅ running${NC}                  ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Cron           ${RED}❌ error${NC}                    ${CYAN}│${NC}"
fi

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
if [ "$HAVE_BOXD_CLI" = true ]; then
    echo -e "  Hermes Studio: ${BLUE}https://${MACHINE_NAME}.boxd.sh${NC}"
    echo -e "  9Router:       ${BLUE}https://router.${MACHINE_NAME}.boxd.sh${NC}"
else
    echo -e "  ${YELLOW}(boxd CLI not detected - run 'boxd machine proxy list' on a real boxd VM to see your URLs)${NC}"
fi
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
if [ "$HAVE_BOXD_CLI" = true ]; then
    echo -e "  • boxd suspends this VM after idle network time. If you need the"
    echo -e "    watchdog/cron loop to keep ticking with no inbound traffic, run:"
    echo -e "    ${BLUE}boxd machine config set ${MACHINE_NAME} auto-hibernate.timeout 0${NC}"
fi
echo ""
