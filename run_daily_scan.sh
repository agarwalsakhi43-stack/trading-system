#!/bin/bash
# run_daily_scan.sh — convenience wrapper: adds start notification + logging, then calls master_scan.sh
# Usage: ./run_daily_scan.sh --mode morning|evening|weekly [other master_scan.sh flags]
#
# Stock universe flow:
#   weekly_fundamental_scan.sh reads nifty500_watchlist.json (336 stocks)
#   → saves approved stocks (STRONG BUY + BUY) to approved_stocks.json
#   → master_scan.sh reads approved_stocks.json for daily technical scans
# To expand the daily scan universe, run weekly_fundamental_scan.sh with an updated watchlist.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="morning"

# Peek at --mode arg to customise the notification subtitle
for arg in "$@"; do
  case "$prev" in --mode) MODE="$arg" ;; esac
  prev="$arg"
done

case "$MODE" in
  morning) SUBTITLE="SMA80 Positional + Intraday — market opens in ~15 min" ;;
  evening) SUBTITLE="Swing + Candlestick setups — EOD check"                ;;
  weekly)  SUBTITLE="Dow Theory long-term scan"                               ;;
  *)       SUBTITLE="Technical scan starting…"                                ;;
esac

/usr/bin/osascript -e "display notification \"$SUBTITLE\" with title \"📈 Master Scan Started ($MODE)\""

LOG_FILE="$SCRIPT_DIR/logs/${MODE}_scan.log"
mkdir -p "$SCRIPT_DIR/logs"

cd "$SCRIPT_DIR" && bash master_scan.sh "$@" | tee -a "$LOG_FILE"
