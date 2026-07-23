#!/bin/bash
# autowake_scan.sh — triggered frequently by launchd (com.trading.autowake.plist)
# across two checkpoint windows, since launchd has no native "on system wake"
# trigger — StartCalendarInterval is the closest real primitive. The plist
# fires this script every 5 minutes across 9:05-9:35 AM and 3:20-3:50 PM
# (Mon-Fri); this script self-gates on the EXACT target windows
# (9:10-9:30 AM / 3:25-3:45 PM) and exits immediately outside them.
#
# A once-per-day marker file prevents the scan from running multiple times
# during repeated 5-minute firings within the same window (e.g. firing at
# 9:10, 9:15, 9:20... would otherwise re-run the scan — and send duplicate
# notifications — up to 5 times in one morning).
#
# Combine with: sudo pmset repeat wakeorpoweron MTWRF 09:10:00 sleep MTWRF 16:00:00
# (already configured) — that's what actually wakes/sleeps the Mac; this
# script is what runs once the Mac is awake and launchd's checks land inside
# a target window.
#
# Testing: set FORCE_MODE=morning or FORCE_MODE=evening to bypass the time
# gate and marker check for a manual end-to-end test. Never set in production
# — launchd invokes this with no environment overrides.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TODAY=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/autowake_scan_${TODAY}.log"

exec >> "$LOG_FILE" 2>&1

NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
# Force base-10 interpretation — a plain zero-padded "0917" would otherwise be
# misread as an (invalid) octal literal by bash's arithmetic/test operators.
NOW_HM=$((10#$(date +%H%M)))

MODE=""
MARKER=""

if [ -n "$FORCE_MODE" ]; then
  MODE="$FORCE_MODE"
  MARKER="$LOG_DIR/.autowake_${MODE}_ran_${TODAY}_TEST"
  echo "[$NOW_HUMAN] FORCE_MODE=$FORCE_MODE set — bypassing time gate (test mode)."
elif [ "$NOW_HM" -ge 910 ] && [ "$NOW_HM" -le 930 ]; then
  MODE="morning"
  MARKER="$LOG_DIR/.autowake_morning_ran_${TODAY}"
elif [ "$NOW_HM" -ge 1525 ] && [ "$NOW_HM" -le 1545 ]; then
  MODE="evening"
  MARKER="$LOG_DIR/.autowake_evening_ran_${TODAY}"
fi

if [ -z "$MODE" ]; then
  # Outside both windows — silent no-op. Not logged, to avoid ~150+ lines/day
  # of "nothing to do" noise from the 5-minute checkpoint firings.
  exit 0
fi

if [ -f "$MARKER" ]; then
  echo "[$NOW_HUMAN] $MODE scan already ran today (marker: $MARKER) — skipping duplicate trigger."
  exit 0
fi

echo ""
echo "════════════════════════════════════════════════════"
echo "Autowake $MODE scan triggered: $NOW_HUMAN (HHMM=$NOW_HM)"
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

echo "Waiting 10s for the chart to stabilize..."
sleep 10

echo "Running master_scan.sh --mode $MODE..."
"$SCRIPT_DIR/master_scan.sh" --mode "$MODE" --verbose

touch "$MARKER"
echo "Autowake $MODE scan finished: $(date '+%Y-%m-%d %H:%M:%S') — marker written: $MARKER"
