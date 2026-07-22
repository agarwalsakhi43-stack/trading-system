#!/bin/bash
# morning_auto_scan.sh — Unattended routine triggered by launchd after the Mac
# wakes (see pmset wakeorpoweron + com.sakhi.tradingsystem.morningscan.plist).
#
# 1. Ensures TradingView is running with CDP enabled (launches it if not)
# 2. Waits for the CDP port to actually accept connections
# 3. Runs master_scan.sh --mode morning
#
# Runs Mon-Fri only via the launchd schedule (NSE is closed weekends, so this
# script doesn't bother re-checking the day itself — that's the plist's job).
# All output goes to a dated log file since nobody's watching a terminal —
# notify.sh / notify_telegram.sh (called by master_scan.sh) are the actual
# "tell me what happened" channel.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/morning_auto_scan_$(date +%Y-%m-%d).log"

exec >> "$LOG_FILE" 2>&1

echo ""
echo "════════════════════════════════════════════════════"
echo "Morning auto-scan triggered: $(date '+%Y-%m-%d %H:%M:%S')"
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

# Give the chart a bit more time to fully load past the CDP handshake
echo "Waiting 15s for the chart to stabilize..."
sleep 15

echo "Running master_scan.sh --mode morning..."
"$SCRIPT_DIR/master_scan.sh" --mode morning --verbose

echo "Morning auto-scan finished: $(date '+%Y-%m-%d %H:%M:%S')"
