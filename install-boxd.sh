#!/bin/bash
# ============================================================
# Boxd Precise URL Resolver & Health Checker
# ============================================================

HERMES_PORT=6060
ROUTER_PORT=20127

# دریافت شناسه باکس
BOX_ID="${BOXD_BOX_ID:-${BOX_ID:-$(hostname)}}"

echo -e "\033[1;36m[+] Box ID Detected:\033[0m ${BOX_ID}"
echo -e "\033[1;33m[+] Checking network reachability for exposed ports...\033[0m\n"

# لیست تمام الگوهای معتبر لینک در Boxd
HERMES_PATTERNS=(
  "https://${BOX_ID}-${HERMES_PORT}.boxd.sh"
  "https://${HERMES_PORT}.${BOX_ID}.boxd.sh"
  "https://${BOX_ID}.boxd.sh"
)

ROUTER_PATTERNS=(
  "https://${BOX_ID}-${ROUTER_PORT}.boxd.sh"
  "https://${ROUTER_PORT}.${BOX_ID}.boxd.sh"
  "https://router.${BOX_ID}.boxd.sh"
)

# تابع تست HTTP
test_working_url() {
  local urls=("$@")
  for url in "${urls[@]}"; do
    # ارسال درخواست با timeout 3 ثانیه
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
    if [ "$code" -ne 000 ] && [ "$code" -ne 502 ]; then
      echo "$url"
      return 0
    fi
  done
  echo ""
}

WORKING_HERMES=$(test_working_url "${HERMES_PATTERNS[@]}")
WORKING_ROUTER=$(test_working_url "${ROUTER_PATTERNS[@]}")

echo "===================================================="
if [ -n "$WORKING_HERMES" ]; then
  echo -e "\033[0;32m✔ Hermes Studio URL:\033[0m ${WORKING_HERMES}"
else
  echo -e "\033[0;31m✘ Hermes Studio URL:\033[0m https://${BOX_ID}-${HERMES_PORT}.boxd.sh (سرویس روی پورت 6060 پاسخ نداد)"
fi

if [ -n "$WORKING_ROUTER" ]; then
  echo -e "\033[0;32m✔ 9Router URL:\033[0m       ${WORKING_ROUTER}"
else
  echo -e "\033[0;31m✘ 9Router URL:\033[0m       https://${BOX_ID}-${ROUTER_PORT}.boxd.sh (سرویس روی پورت 20127 پاسخ نداد)"
fi
echo "===================================================="
