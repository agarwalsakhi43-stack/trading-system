#!/bin/bash
# evening_auto_scan.sh — Unattended routine triggered by launchd at 3:30 PM
# (see com.sakhi.tradingsystem.eveningscan.plist). Mirrors morning_auto_scan.sh
# but runs master_scan.sh --mode evening (Swing Setup + Candlestick Reversal)
# instead of morning mode.
#
# Assumes the Mac is already awake (pmset repeat wakes it once at 9:10 AM and
# sleeps it once at 4:00 PM — it stays on through both scan windows rather
# than sleeping and re-waking between them; see pmset repeat docs, which only
# support one wake+sleep pair, not two independent daily wake times).
#
# All output goes to a dated log file since nobody's watching a terminal —
# notify.sh / notify_telegram.sh (called by master_scan.sh) are the actual
# "tell me what happened" channel.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/evening_auto_scan_$(date +%Y-%m-%d).log"

exec >> "$LOG_FILE" 2>&1

echo ""
echo "════════════════════════════════════════════════════"
echo "Evening auto-scan triggered: $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════"

CDP_PORT=9222

is_cdp_up() {
  lsof -i ":${CDP_PORT}" 2>/dev/null | grep -q LISTEN
}

if is_cdp_up; then
  echo "TradingView already running with CDP on port ${CDP_PORT}."
else
  echo "TradingView not running — launching with remote debugging enabled..."
  /Applications/TradingView.app/Contents/MacOS/TradingView --remote-debugging-port="${CDP_PORT}" &

  echo "Waiting for CDP to come up (up to 60s)..."
  READY=false
  for i in $(seq 1 30); do
    sleep 2
    if is_cdp_up; then
      echo "CDP ready after $(( i * 2 ))s."
      READY=true
      break
    fi
  done
  if [ "$READY" != true ]; then
    echo "❌ CDP never came up after 60s — aborting scan. Check TradingView manually."
    exit 1
  fi
fi

echo "Waiting 15s for the chart to stabilize..."
sleep 15

echo "Running master_scan.sh --mode evening..."
"$SCRIPT_DIR/master_scan.sh" --mode evening --verbose

echo "Evening auto-scan finished: $(date '+%Y-%m-%d %H:%M:%S')"
