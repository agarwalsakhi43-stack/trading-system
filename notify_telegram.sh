#!/bin/bash
# notify_telegram.sh — Send a Telegram message via the trading bot (parallel to notify.sh)
# Usage: ./notify_telegram.sh "Title" "Message"
#
# Degrades gracefully: if telegram_config.sh is missing or the API call fails,
# this prints a warning to stderr and exits 0 rather than breaking the caller's
# scan/notification pipeline.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/telegram_config.sh"

TITLE="${1:-Trading Alert}"
MESSAGE="${2:-Signal triggered}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "⚠️   notify_telegram.sh: telegram_config.sh not found — skipping Telegram notification" >&2
  exit 0
fi

source "$CONFIG_FILE"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  echo "⚠️   notify_telegram.sh: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set — skipping" >&2
  exit 0
fi

TEXT="${TITLE}
${MESSAGE}"

RESPONSE=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${TEXT}")

if ! echo "$RESPONSE" | grep -q '"ok":true'; then
  echo "⚠️   notify_telegram.sh: Telegram API call failed — $RESPONSE" >&2
fi

exit 0
