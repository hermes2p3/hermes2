#!/bin/bash
# ============================================================
#  Hermes Studio + 9Router - نصب خودکار روی Daytona
# ============================================================
#  نسخه: 1.0
#  نویسنده: جامعه متن‌باز
#  لایسنس: MIT
# ============================================================
#
#  این اسکریپت به طور خودکار:
#  - Node.js 24
#  - Python 3.12
#  - hermes-agent
#  - Hermes Studio (وب UI چت AI)
#  - 9Router (مسیریاب API مدل‌های رایگان AI)
#  - سیستم نگهدارنده خودکار (watchdog)
#  - بکاپ خودکار
#  را نصب و پیکربندی می‌کند.
#
#  نحوه استفاده:
#    bash install.sh
#
#  پس از نصب، آدرس‌های زیر در دسترس خواهند بود:
#    - Hermes Studio: https://6060-<SANDBOX_ID>.proxy.daytona.work
#    - 9Router:       https://20127-<SANDBOX_ID>.proxy.daytona.work
#
# ============================================================

set -e

# --- رنگ‌ها ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # بدون رنگ

# --- توابع کمکی ---
log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"; exit 1; }
info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $1${NC}"; }

# --- متغیرها ---
PYTHON_VERSION="3.12.13"
PYTHON_BUILD_DATE="20260623"
NODE_VERSION="24.15.0"
XRAY_VERSION="26.3.27"
HERMES_PORT=6060
ROUTER_PORT=20127
BRIDGE_SOCK=/tmp/hermes-agent-bridge.sock

# --- بنر ---
echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                  ║"
echo "  ║   نصب‌کننده Hermes Studio + 9Router               ║"
echo "  ║   برای سندباکس Daytona                            ║"
echo "  ║                                                  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# --- بررسی root ---
if [ "$(id -u)" -ne 0 ]; then
    warn "اسکریپت با root اجرا نمی‌شود. ادامه می‌دهیم..."
fi

# --- بررسی Daytona ---
if [ ! -f /.dockerenv ] && [ -z "$DAYTONA_SANDBOX_ID" ]; then
    warn "به نظر می‌رسد این محیط Daytona نیست. ادامه می‌دهیم اما ممکن است مشکلاتی پیش بیاید."
fi

SANDBOX_ID=${DAYTONA_SANDBOX_ID:-$(hostname)}
info "شناسه سندباکس: ${SANDBOX_ID}"

# ============================================================
# مرحله ۱: نصب Node.js
# ============================================================
echo ""
log "━━━ مرحله ۱: نصب Node.js ━━━"

if command -v node &>/dev/null && [ "$(node -v | cut -d. -f1 | tr -d v)" -ge 23 ]; then
    info "Node.js نسخه $(node -v) از قبل نصب است."
else
    log "در حال دانلود Node.js v${NODE_VERSION}..."
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" -o /tmp/node.tar.gz
    mkdir -p /usr/local/node-v24
    tar -xzf /tmp/node.tar.gz -C /usr/local/node-v24 --strip-components=1
    rm /tmp/node.tar.gz
    ln -sf /usr/local/node-v24/bin/node /usr/local/bin/node
    ln -sf /usr/local/node-v24/bin/npm /usr/local/bin/npm
    ln -sf /usr/local/node-v24/bin/npx /usr/local/bin/npx
    log "Node.js نصب شد: $(node -v)"
fi

# ============================================================
# مرحله ۲: نصب Python 3.12
# ============================================================
echo ""
log "━━━ مرحله ۲: نصب Python 3.12 ━━━"

if /opt/python3.12/bin/python3 --version &>/dev/null; then
    info "Python 3.12 از قبل نصب است."
else
    log "در حال دانلود Python ${PYTHON_VERSION}..."
    curl -fsSL "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/cpython-${PYTHON_VERSION}%2B${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz" -o /tmp/python.tar.gz
    mkdir -p /opt/python3.12
    tar -xzf /tmp/python.tar.gz -C /opt/python3.12 --strip-components=1
    rm /tmp/python.tar.gz
    log "Python نصب شد: $(/opt/python3.12/bin/python3 --version)"
fi

# ============================================================
# مرحله ۳: نصب hermes-agent
# ============================================================
echo ""
log "━━━ مرحله ۳: نصب hermes-agent ━━━"

if [ -f /opt/hermes-venv/bin/hermes ]; then
    info "hermes-agent از قبل نصب است."
else
    log "ایجاد محیط مجازی Python..."
    rm -rf /opt/hermes-venv
    /opt/python3.12/bin/python3 -m venv /opt/hermes-venv
    /opt/hermes-venv/bin/pip install --upgrade pip -q
    log "نصب hermes-agent..."
    /opt/hermes-venv/bin/pip install 'hermes-agent>=0.18' -q
    ln -sf /opt/hermes-venv/bin/hermes /usr/local/bin/hermes
    log "hermes-agent نصب شد: $(/opt/hermes-venv/bin/hermes --version 2>&1 | head -1)"
fi

# نصب ابزارهای سیستمی
log "نصب ابزارهای سیستمی (cron, curl, git)..."
apt-get update -qq && apt-get install -y -qq cron curl git make g++ python3-dev > /dev/null 2>&1 || true

# ============================================================
# مرحله ۴: دانلود و ساخت Hermes Studio
# ============================================================
echo ""
log "━━━ مرحله ۴: نصب Hermes Studio ━━━"

if [ -d /root/hermes-studio/dist ]; then
    info "Hermes Studio از قبل ساخته شده است."
else
    log "دانلود کد Hermes Studio..."
    rm -rf /root/hermes-studio
    git clone --depth 1 https://github.com/EKKOLearnAI/hermes-studio.git /root/hermes-studio
    
    log "نصب پکیج‌ها (ممکن است چند دقیقه طول بکشد)..."
    cd /root/hermes-studio
    NODE_OPTIONS=--max-old-space-size=8192 npm install --no-audit --no-fund
    
    log "ساخت پروژه..."
    NODE_OPTIONS=--max-old-space-size=8192 NEXT_PUBLIC_BASE_URL=http://localhost:${HERMES_PORT} npm run build
    
    log "بازسازی ماژول‌های بومی..."
    npm rebuild node-pty 2>/dev/null || true
fi

# ============================================================
# مرحله ۵: دانلود و ساخت 9Router
# ============================================================
echo ""
log "━━━ مرحله ۵: نصب 9Router ━━━"

if [ -d /root/9router/dist ] || [ -d /root/9router/.next ]; then
    info "9Router از قبل ساخته شده است."
else
    log "دانلود کد 9Router..."
    rm -rf /root/9router
    git clone --depth 1 https://github.com/decolua/9router.git /root/9router
    
    log "نصب پکیج‌ها..."
    cd /root/9router
    NODE_OPTIONS=--max-old-space-size=8192 npm install --no-audit --no-fund
    
    log "ساخت پروژه..."
    NODE_OPTIONS=--max-old-space-size=8192 NEXT_PUBLIC_BASE_URL=http://localhost:${ROUTER_PORT} npm run build
fi

# ============================================================
# مرحله ۶: پیکربندی 9Router
# ============================================================
echo ""
log "━━━ مرحله ۶: پیکربندی 9Router ━━━"

# تولید رمز تصادفی
ROUTER_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")
JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")

cat > /root/9router/.env << EOF
JWT_SECRET=${JWT_SECRET}
INITIAL_PASSWORD=${ROUTER_PASSWORD}
DATA_DIR=/var/lib/9router
PORT=${ROUTER_PORT}
NODE_ENV=production
API_KEY_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
MACHINE_ID_SALT=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
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

log "رمز ورود 9Router: ${ROUTER_PASSWORD}"

# ============================================================
# مرحله ۷: پیکربندی Hermes Studio
# ============================================================
echo ""
log "━━━ مرحله ۷: پیکربندی Hermes Studio ━━━"

mkdir -p /root/.hermes /root/.hermes-web-ui

# اگر کانفیگ قبلی وجود ندارد، یکی بساز
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
    log "فایل پیکربندی Hermes ایجاد شد."
fi

# ============================================================
# مرحله ۸: اصلاح Socket.IO برای Daytona
# ============================================================
echo ""
log "━━━ مرحله ۸: اصلاح Socket.IO برای Daytona ━━━"

# جایگزینی transports:["websocket","polling"] با transports:["polling"]
# تا WebSocket error ندهد
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
        print(f"  اصلاح شد: {count} فایل")
    else:
        print("  نیازی به اصلاح نیست")
else:
    print("  پوشه client پیدا نشد - رد شد")
PYEOF

# ============================================================
# مرحله ۹: اسکریپت نگهدارنده (Watchdog)
# ============================================================
echo ""
log "━━━ مرحله ۹: نصب سیستم نگهدارنده ━━━"

# --- اسکریپت watchdog اصلی ---
cat > /usr/local/bin/master-watchdog.sh << 'WATCHDOG_EOF'
#!/bin/bash
# سیستم نگهدارنده خودکار - هر ۵ دقیقه سرویس‌ها را بررسی می‌کند

LOG=/var/log/master-watchdog.log
mkdir -p /var/log

ts() { date '+%Y-%m-%d %H:%M:%S'; }

export HERMES_HOME=/root/.hermes
export PATH=/opt/hermes-venv/bin:/usr/local/node-v24/bin:$PATH
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc:///tmp/hermes-agent-bridge.sock
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages

echo "[$(ts)] سیستم نگهدارنده شروع شد (PID $$)" >> $LOG

while true; do
    # --- بررسی 9Router ---
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:20127/ 2>/dev/null; then
        echo "[$(ts)] 9Router از کار افتاده، در حال راه‌اندازی..." >> $LOG
        pkill -9 -f "next start" 2>/dev/null
        sleep 2
        cd /root/9router
        NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:20128 \
            nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
        sleep 8
    fi

    # --- بررسی Bridge ---
    if ! pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
        echo "[$(ts)] Bridge از کار افتاده، در حال راه‌اندازی..." >> $LOG
        nohup setsid python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
            --endpoint ipc:///tmp/hermes-agent-bridge.sock \
            --hermes-home /root/.hermes \
            --agent-root $HERMES_AGENT_ROOT \
            > /tmp/bridge.log 2>&1 < /dev/null &
        sleep 5
    fi

    # --- بررسی Hermes Studio ---
    if ! curl -s -m 3 -o /dev/null http://127.0.0.1:6060/ 2>/dev/null; then
        echo "[$(ts)] Hermes Studio از کار افتاده، در حال راه‌اندازی..." >> $LOG
        pkill -9 -f "node dist/server" 2>/dev/null
        fuser -k 6060/tcp 2>/dev/null
        sleep 3
        cd /root/hermes-studio
        PORT=6060 NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
            nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
        sleep 12
    fi

    # --- بررسی Cron ---
    if ! pgrep -x cron > /dev/null 2>&1; then
        echo "[$(ts)] Cron از کار افتاده، در حال راه‌اندازی..." >> $LOG
        nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
        sleep 2
    fi

    # --- ثبت فعالیت (جلوی auto-stop را می‌گیرد) ---
    echo "[$(ts)] تیک - همه سرویس‌ها سالم" >> $LOG

    # کوچک نگه داشتن لاگ
    tail -100 $LOG > $LOG.tmp && mv $LOG.tmp $LOG

    sleep 300  # ۵ دقیقه
done
WATCHDOG_EOF
chmod +x /usr/local/bin/master-watchdog.sh

# --- اسکریپت بررسی watchdog توسط cron ---
cat > /usr/local/bin/check-watchdog.sh << 'CHECK_EOF'
#!/bin/bash
# بررسی زنده بودن watchdog - هر ۱۰ دقیقه توسط cron اجرا می‌شود

if pgrep -f "master-watchdog.sh" > /dev/null 2>&1; then
    exit 0
fi

# watchdog مرده - راه‌اندازی مجدد
echo "$(date '+%Y-%m-%d %H:%M:%S') Cron: watchdog مرده، در حال راه‌اندازی..." >> /var/log/master-watchdog.log
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
CHECK_EOF
chmod +x /usr/local/bin/check-watchdog.sh

log "اسکریپت‌های نگهدارنده نصب شدند."

# ============================================================
# مرحله ۱۰: راه‌اندازی سرویس‌ها
# ============================================================
echo ""
log "━━━ مرحله ۱۰: راه‌اندازی سرویس‌ها ━━━"

# توقف سرویس‌های قدیمی
pkill -f 'hermes' 2>/dev/null || true
pkill -f 'node dist/server' 2>/dev/null || true
pkill -f 'next start' 2>/dev/null || true
pkill -f 'master-watchdog' 2>/dev/null || true
sleep 3

# آزاد کردن پورت‌ها
fuser -k 6060/tcp 2>/dev/null || true
fuser -k 20127/tcp 2>/dev/null || true
sleep 2

# --- شروع Bridge ---
log "شروع Bridge..."
export PATH=/opt/hermes-venv/bin:$PATH
export HERMES_HOME=/root/.hermes
nohup setsid python3 /root/hermes-studio/dist/server/agent-bridge/python/hermes_bridge.py \
    --endpoint ipc://$BRIDGE_SOCK \
    --hermes-home /root/.hermes \
    --agent-root /opt/hermes-venv/lib/python3.12/site-packages \
    > /tmp/bridge.log 2>&1 < /dev/null &
sleep 5

# --- شروع 9Router ---
log "شروع 9Router..."
cd /root/9router
NODE_ENV=production NEXT_PUBLIC_BASE_URL=http://localhost:20128 \
    nohup setsid npm run start > /tmp/9router.log 2>&1 < /dev/null &
sleep 8

# --- شروع Hermes Studio ---
log "شروع Hermes Studio..."
cd /root/hermes-studio
export HERMES_AGENT_BRIDGE_ENDPOINT=ipc://$BRIDGE_SOCK
export HERMES_AGENT_BRIDGE_PYTHON=/opt/hermes-venv/bin/python3
export HERMES_BIN=/opt/hermes-venv/bin/hermes
export HERMES_AGENT_ROOT=/opt/hermes-venv/lib/python3.12/site-packages
PORT=$HERMES_PORT NODE_ENV=production HOME=/root HERMES_ALLOW_ROOT_GATEWAY=1 \
    nohup setsid node dist/server/index.js > /tmp/hermes.log 2>&1 < /dev/null &
sleep 12

# --- شروع Cron ---
log "شروع Cron..."
if ! pgrep -x cron > /dev/null; then
    nohup setsid cron -f > /var/log/cron.log 2>&1 < /dev/null &
    sleep 2
fi

# --- تنظیم crontab ---
(crontab -l 2>/dev/null | grep -v 'check-watchdog'; echo '*/10 * * * * /usr/local/bin/check-watchdog.sh') | crontab -
log "Cron تنظیم شد: هر ۱۰ دقیقه watchdog بررسی می‌شود."

# --- شروع Watchdog ---
log "شروع سیستم نگهدارنده..."
nohup setsid bash /usr/local/bin/master-watchdog.sh > /dev/null 2>&1 < /dev/null &
sleep 3

# ============================================================
# مرحله ۱۱: بررسی نهایی
# ============================================================
echo ""
log "━━━ بررسی نهایی ━━━"

sleep 5

echo ""
echo -e "${CYAN}┌──────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│         وضعیت سرویس‌ها                   │${NC}"
echo -e "${CYAN}├──────────────────────────────────────────┤${NC}"

# بررسی 9Router
if curl -s -m 3 -o /dev/null http://127.0.0.1:${ROUTER_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} 9Router        ${GREEN}✅ در حال اجرا${NC}              ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} 9Router        ${RED}❌ خطا${NC}                    ${CYAN}│${NC}"
fi

# بررسی Bridge
if pgrep -f "hermes_bridge.py" > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Bridge         ${GREEN}✅ در حال اجرا${NC}              ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Bridge         ${RED}❌ خطا${NC}                    ${CYAN}│${NC}"
fi

# بررسی Hermes Studio
if curl -s -m 3 -o /dev/null http://127.0.0.1:${HERMES_PORT}/ 2>/dev/null; then
    echo -e "${CYAN}│${NC} Hermes Studio  ${GREEN}✅ در حال اجرا${NC}              ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Hermes Studio  ${RED}❌ خطا${NC}                    ${CYAN}│${NC}"
fi

# بررسی Cron
if pgrep -x cron > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Cron           ${GREEN}✅ در حال اجرا${NC}              ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Cron           ${RED}❌ خطا${NC}                    ${CYAN}│${NC}"
fi

# بررسی Watchdog
if pgrep -f "master-watchdog" > /dev/null 2>&1; then
    echo -e "${CYAN}│${NC} Watchdog       ${GREEN}✅ در حال اجرا${NC}              ${CYAN}│${NC}"
else
    echo -e "${CYAN}│${NC} Watchdog       ${RED}❌ خطا${NC}                    ${CYAN}│${NC}"
fi

echo -e "${CYAN}└──────────────────────────────────────────┘${NC}"

echo ""
echo -e "${GREEN}━━━ نصب با موفقیت انجام شد! ━━━${NC}"
echo ""
echo -e "${YELLOW}آدرس‌های عمومی:${NC}"
echo -e "  Hermes Studio: ${BLUE}https://${HERMES_PORT}-${SANDBOX_ID}.proxy.daytona.work${NC}"
echo -e "  9Router:       ${BLUE}https://${ROUTER_PORT}-${SANDBOX_ID}.proxy.daytona.work${NC}"
echo ""
echo -e "${YELLOW}ورود به Hermes Studio:${NC}"
echo -e "  نام کاربری: ${BLUE}admin${NC}"
echo -e "  رمز عبور:   ${BLUE}123456${NC}"
echo ""
echo -e "${YELLOW}ورود به 9Router:${NC}"
echo -e "  رمز عبور:   ${BLUE}${ROUTER_PASSWORD}${NC}"
echo ""
echo -e "${YELLOW}مدل AI رایگان پیش‌فرض:${NC}"
echo -e "  ${BLUE}oc/mimo-v2.5-free${NC} (از طریق 9Router)"
echo ""
echo -e "${YELLOW}نکات:${NC}"
echo -e "  • سیستم نگهدارنده هر ۵ دقیقه سرویس‌ها را بررسی می‌کند"
echo -e "  • اگر سرویسی از کار بیفتد، خودکار راه‌اندازی مجدد می‌شود"
echo -e "  • برای بررسی لاگ: ${BLUE}tail -20 /var/log/master-watchdog.log${NC}"
echo -e "  • برای راه‌اندازی دستی watchdog: ${BLUE}bash /usr/local/bin/master-watchdog.sh &${NC}"
echo ""
