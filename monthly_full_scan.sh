#!/bin/bash
# monthly_full_scan.sh — REFINED fundamental scan across all full_market_watchlist.json stocks
# Runs on 1st of every month at 11 PM. Saves approved (STRONG BUY + BUY) to approved_stocks_full.json.
# Usage: ./monthly_full_scan.sh [--verbose]
# NOTE: With 426+ stocks, expect ~85-100 minutes per run. Extend full_market_watchlist.json
#       with official NSE/BSE security master data to grow to ~7500 stocks.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FUND_CHECK="$SCRIPT_DIR/fundamental_check.sh"
WATCHLIST_FILE="$SCRIPT_DIR/full_market_watchlist.json"
APPROVED_FILE="$SCRIPT_DIR/approved_stocks_full.json"

VERBOSE=false
[ "$1" = "--verbose" ] && VERBOSE=true

mkdir -p "$SCRIPT_DIR/logs"

# ── Load stock list ─────────────────────────────────────────────
if [ ! -f "$WATCHLIST_FILE" ]; then
  echo "  ❌  full_market_watchlist.json not found in $SCRIPT_DIR"
  exit 1
fi

STOCK_LIST=$(node --input-type=module << JSEOF
import { readFileSync } from 'fs';
const d = JSON.parse(readFileSync('$WATCHLIST_FILE', 'utf8'));
console.log(d.stocks.map(s => s.symbol).join(' '));
JSEOF
)
set -- $STOCK_LIST
TOTAL=$#
EST_MINS=$(( TOTAL * 12 / 60 ))

# ── Header ──────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  %-56s║\n" "MONTHLY FULL MARKET SCAN — REFINED Framework"
printf "║  %-56s║\n" "$(date '+%A, %d %b %Y  %I:%M %p')"
printf "║  %-56s║\n" "Universe : $TOTAL stocks from full_market_watchlist.json"
printf "║  %-56s║\n" "Est. time: ~$EST_MINS minutes"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Temp file: one line per approved stock as SYMBOL|VERDICT ────
TEMP_APPROVED=$(mktemp)
trap "rm -f $TEMP_APPROVED" EXIT

IDX=0
STRONG_COUNT=0
BUY_COUNT=0
WATCH_COUNT=0
AVOID_COUNT=0

for STOCK in "$@"; do
  IDX=$(( IDX + 1 ))
  printf "  [%3d/%d] %-14s  ⟳  Checking…" "$IDX" "$TOTAL" "$STOCK"

  FUND_OUTPUT=$("$FUND_CHECK" "$STOCK" 2>&1)
  $VERBOSE && echo "" && echo "$FUND_OUTPUT"

  VERDICT_LINE=$(echo "$FUND_OUTPUT" | grep "FINAL VERDICT:")
  if echo "$VERDICT_LINE" | grep -q "STRONG BUY"; then
    (( STRONG_COUNT++ ))
    echo "$STOCK|STRONG BUY" >> "$TEMP_APPROVED"
    printf "\r  [%3d/%d] %-14s  ⭐ STRONG BUY\n" "$IDX" "$TOTAL" "$STOCK"
  elif echo "$VERDICT_LINE" | grep -q " BUY"; then
    (( BUY_COUNT++ ))
    echo "$STOCK|BUY" >> "$TEMP_APPROVED"
    printf "\r  [%3d/%d] %-14s  🟢 BUY\n" "$IDX" "$TOTAL" "$STOCK"
  elif echo "$VERDICT_LINE" | grep -q "WATCH"; then
    (( WATCH_COUNT++ ))
    printf "\r  [%3d/%d] %-14s  🟡 WATCH — not approved\n" "$IDX" "$TOTAL" "$STOCK"
  else
    (( AVOID_COUNT++ ))
    printf "\r  [%3d/%d] %-14s  🔴 AVOID — rejected\n" "$IDX" "$TOTAL" "$STOCK"
  fi
done

APPROVED_TOTAL=$(( STRONG_COUNT + BUY_COUNT ))

echo ""
echo "  ─────────────────────────────────────────────────────────"
printf "  ⭐ Strong Buy : %-3s  🟢 Buy : %-3s  🟡 Watch : %-3s  🔴 Avoid : %-3s\n" \
  "$STRONG_COUNT" "$BUY_COUNT" "$WATCH_COUNT" "$AVOID_COUNT"
printf "  Total approved for technical scan : %s / %s\n" "$APPROVED_TOTAL" "$TOTAL"
echo "  ─────────────────────────────────────────────────────────"
echo ""
echo "  Writing approved_stocks_full.json…"

# ── Write approved_stocks_full.json via Node ─────────────────────────
export TEMP_APPROVED WATCHLIST_FILE APPROVED_FILE
export SCAN_DATE=$(date '+%Y-%m-%d')
export TOTAL_SCANNED="$TOTAL"

node --input-type=module <<'JSEOF'
import { readFileSync, writeFileSync } from 'fs';

const watchlist = JSON.parse(readFileSync(process.env.WATCHLIST_FILE, 'utf8'));
const metaMap   = {};
watchlist.stocks.forEach(s => { metaMap[s.symbol] = s; });

const lines   = readFileSync(process.env.TEMP_APPROVED, 'utf8').split('\n').filter(Boolean);
const stocks  = lines.map(line => {
  const sep     = line.indexOf('|');
  const symbol  = line.slice(0, sep);
  const verdict = line.slice(sep + 1);
  const m       = metaMap[symbol] || {};
  return {
    symbol,
    name:      m.name      || symbol,
    sector:    m.sector    || 'Unknown',
    sub_index: m.sub_index || '',
    verdict,
    approved_on: process.env.SCAN_DATE
  };
});

const output = {
  last_scan:      process.env.SCAN_DATE,
  total_scanned:  parseInt(process.env.TOTAL_SCANNED),
  total_approved: stocks.length,
  strong_buy:     stocks.filter(s => s.verdict === 'STRONG BUY').length,
  buy:            stocks.filter(s => s.verdict === 'BUY').length,
  stocks
};

writeFileSync(process.env.APPROVED_FILE, JSON.stringify(output, null, 2));
console.log(`  ✅  Saved ${stocks.length} approved stocks → approved_stocks_full.json`);
JSEOF

echo ""

# ── Notification ────────────────────────────────────────────────
/usr/bin/osascript -e "display notification \"⭐ $STRONG_COUNT Strong Buy · 🟢 $BUY_COUNT Buy · $TOTAL_SCANNED scanned\" with title \"📋 Monthly Full Scan Complete — $APPROVED_TOTAL approved\""

echo "  🔔  Notification sent."
echo ""
