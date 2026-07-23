#!/bin/bash
# master_scan.sh — Strategy-based technical scan on fundamentally pre-approved stocks
# Reads from approved_stocks.json (built by weekly_fundamental_scan.sh)
#
# Usage:
#   ./master_scan.sh --mode morning   # 9:15 AM — EMA80 Positional + Intraday Momentum
#   ./master_scan.sh --mode evening   # 3:30 PM — Swing Setup + Candlestick Reversal
#   ./master_scan.sh --mode weekly    # Saturday — Long-term Dow Theory
#
# Strategy preferences (per strategy_selector.md, based on 2-year backtest —
# see backtest.sh / backtest_results.txt / backtest_full_results.txt):
#
# PRIORITY 1 — stock_strategy_map.json (per-stock override, checked first):
#   From the comprehensive 12-strategy x 25-stock backtest. Each approved
#   stock maps to its single best-backtested strategy. Only entries with
#   confidence:"high" (>=4 trades in the backtest window) are actually wired
#   to live signals below — confidence:"low" entries (<=3 trades) are treated
#   as noise and fall through to Priority 2, same as an unmapped stock would.
#   This SUPERSEDES the older single-stock ASIANPAINT-Bollinger-Breakout
#   override (+20.1%, one data point) — the fuller 25-stock test found SMA 30
#   works even better for ASIANPAINT (+29.5%, n=12) and is what's mapped now.
#   Also worth noting: Bullish Harami previously looked like "no real edge"
#   across a 6-stock subset and was pulled from strategy_selector.md's active
#   list — but the fuller 25-stock test found it's the *best* strategy for
#   HAL (+16.8%, n=20) and RECLTD (+13.1%, n=14). Both findings are true
#   simultaneously: no general edge, but real edge for those two specific
#   stocks — exactly the kind of thing a per-stock map (not a blanket rule)
#   is supposed to capture. It's back in play for those two stocks only.
#
# PRIORITY 2 — sector-based fallback (unmapped or low-confidence stocks):
#   - EMA 80 is used instead of SMA 80 for the core positional trend filter
#     (beat SMA 80 on RELIANCE +5.7% vs +2.2% and INFY -20.3% vs -21.8%)
#   - FMCG / Consumer sector stocks use a MACD signal-line crossover as the
#     PRIMARY morning-mode strategy instead of the EMA80 cross (NESTLEIND
#     backtest: MACD +22.7%/55.6% win rate vs EMA80 -11.1%). Sector is looked
#     up from approved_stocks.json.
#   - RSI(14) > 30 is REQUIRED alongside the MACD entry for FMCG/Consumer
#     (both the fresh-cross and positional branches). Added because RSI 14 run
#     standalone was the single best strategy in an earlier backtest round
#     (+37.6% / 50% win rate on NESTLEIND, beating MACD's +22.7% alone).
#
# Morning Star and Piercing Pattern remain excluded from live signals even
# where mapped as "best" — both are candlestick patterns whose backtested
# exit (5-day hold / target / stop) requires tracking entry date and price,
# which this stateless daily scanner doesn't do. Bullish Engulfing and
# Bullish Harami are BUY-only here for the same reason (matches the existing
# evening-mode candlestick signals, which have never had a SELL side either).
#
# Signals (morning mode only — the only mode with a documented symmetric
# entry/exit rule in strategy_selector.md):
#   BUY  — EMA80/MACD entry rule fires (fresh cross, positional, or momentum)
#   SELL — price crosses below EMA80, or MACD crosses below its signal line
#          for FMCG/Consumer (the strategy's own documented exit rule)
#   (no signal / WAIT is not notified — only actionable BUY/SELL push out,
#   to avoid ~25 "nothing to do" notifications every scan)
# Every BUY/SELL fires both a Mac notification (notify.sh) and a Telegram
# message (notify_telegram.sh) simultaneously.
#
# Flags:
#   --limit N     scan only first N approved stocks
#   --verbose     show full indicator output per stock

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TV_CLI="$SCRIPT_DIR/tradingview-mcp-jackson/src/cli/index.js"
NOTIFY="$SCRIPT_DIR/notify.sh"
NOTIFY_TG="$SCRIPT_DIR/notify_telegram.sh"
APPROVED_FILE="$SCRIPT_DIR/approved_stocks.json"
STOCK_STRATEGY_MAP_FILE="$SCRIPT_DIR/stock_strategy_map.json"
export APPROVED_FILE STOCK_STRATEGY_MAP_FILE

# Fire both notification channels for one event. Never let a Telegram
# failure block the Mac notification or vice versa.
notify_both() {
  "$NOTIFY" "$1" "$2" || true
  "$NOTIFY_TG" "$1" "$2" || true
}

# ── Parse flags ─────────────────────────────────────────────────
MODE="morning"
LIMIT=0
VERBOSE=false
PARSED_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    shift; MODE="${1:-morning}"; shift ;;
    --limit)   shift; LIMIT="${1:-0}";     shift ;;
    --verbose) VERBOSE=true; shift ;;
    *)         PARSED_ARGS+=("$1"); shift ;;
  esac
done
set -- "${PARSED_ARGS[@]}"

# ── Validate mode ────────────────────────────────────────────────
case "$MODE" in
  morning) MODE_DESC="Morning — EMA80 Positional + Intraday Momentum (MACD for FMCG/Consumer)" ;;
  evening) MODE_DESC="Evening — Swing Setup + Candlestick Reversal"   ;;
  weekly)  MODE_DESC="Weekly  — Long-term Dow Theory"                  ;;
  *)
    echo "  ❌  Unknown mode: $MODE. Use --mode morning|evening|weekly"
    exit 1 ;;
esac

# ── Load approved stocks ─────────────────────────────────────────
if [ $# -eq 0 ]; then
  if [ ! -f "$APPROVED_FILE" ]; then
    echo ""
    echo "  ❌  approved_stocks.json not found."
    echo "      Run ./weekly_fundamental_scan.sh first to build the approved list."
    exit 1
  fi
  STOCK_LIST=$(node --input-type=module << JSEOF
import { readFileSync } from 'fs';
const d = JSON.parse(readFileSync('$APPROVED_FILE', 'utf8'));
console.log(d.stocks.map(s => s.symbol).join(' '));
JSEOF
  )
  set -- $STOCK_LIST
fi

TOTAL_APPROVED=$#
if [ "$LIMIT" -gt 0 ] 2>/dev/null && [ "$LIMIT" -lt "$TOTAL_APPROVED" ]; then
  set -- "${@:1:$LIMIT}"
fi
SCAN_COUNT=$#

mkdir -p "$SCRIPT_DIR/logs"

# ── Header ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  %-56s║\n" "MASTER SCAN — $MODE_DESC"
printf "║  %-56s║\n" "$(date '+%A, %d %b %Y  %I:%M %p')"
printf "║  %-56s║\n" "Stocks : $SCAN_COUNT pre-approved  (of $TOTAL_APPROVED total)"
printf "║  %-56s║\n" "Notify : BUY + SELL  →  Mac + Telegram"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Result arrays ────────────────────────────────────────────────
declare -a BUY_STOCKS BUY_STRATEGIES BUY_PRICES BUY_TARGETS BUY_STOPS BUY_HOLDS
declare -a SELL_STOCKS SELL_STRATEGIES SELL_PRICES SELL_STOPS SELL_HOLDS

# ── Per-stock loop ───────────────────────────────────────────────
IDX=0
for STOCK in "$@"; do
  IDX=$(( IDX + 1 ))
  printf "  [%3d/%d] %-14s  ⟳  Scanning (%s)…" "$IDX" "$SCAN_COUNT" "$STOCK" "$MODE"

  export TECH_SYMBOL="NSE:${STOCK}"
  export TECH_STOCK="$STOCK"
  export SCAN_MODE="$MODE"

  TECH_OUTPUT=$(node --input-type=module <<'JSEOF'
import { execSync } from 'child_process';
import { readFileSync } from 'fs';

const TV_CLI       = process.env.TV_CLI;
const symbol       = process.env.TECH_SYMBOL;
const stockSymbol  = process.env.TECH_STOCK;
const approvedFile = process.env.APPROVED_FILE;
const mapFile      = process.env.STOCK_STRATEGY_MAP_FILE;
const mode         = process.env.SCAN_MODE || 'morning';

// ── Sector lookup (for FMCG/Consumer → MACD override) ──────────
let sector = 'Unknown';
try {
  const approved = JSON.parse(readFileSync(approvedFile, 'utf8'));
  const match = approved.stocks.find(s => s.symbol === stockSymbol);
  if (match?.sector) sector = match.sector;
} catch { /* approved_stocks.json missing or unreadable — default to Unknown */ }
const isFmcgConsumer = /fmcg|consumer/i.test(sector);

// ── Per-stock strategy map (Priority 1 — see header note) ──────
let mapped = null;
try {
  const map = JSON.parse(readFileSync(mapFile, 'utf8'));
  const entry = map.stocks?.[stockSymbol];
  if (entry && entry.confidence === 'high') mapped = entry;
} catch { /* stock_strategy_map.json missing or unreadable — fall through to sector logic */ }

function run(cmd) {
  try { return JSON.parse(execSync(`node "${TV_CLI}" ${cmd}`, { timeout: 15000 }).toString()); }
  catch { return null; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

run(`symbol "${symbol}"`);
await sleep(2500);
run(mode === 'weekly' ? 'timeframe 1W' : 'timeframe 1D');
await sleep(1500);

const quote      = run('quote');
const ohlcv      = run('ohlcv --bars 200');
const liveValues = run('values');

if (!quote?.success || !ohlcv?.success) {
  process.stdout.write('__SIGNAL__:ERROR\n__PRICE__:\n__TARGET__:\n__STOP__:\n__HOLD__:\n__STRATEGY__:ERROR\n__RSI__:\n');
  process.exit(0);
}

const price  = quote.close;
const closes = ohlcv.bars.map(b => b.close);
const bars   = ohlcv.bars;
const n      = closes.length;

// ── EMA 80 (preferred over SMA 80 — see strategy_selector.md) ──
const emaFn = (arr, p) => {
  if (arr.length < p) return null;
  let prev = arr.slice(0, p).reduce((a, b) => a + b, 0) / p;
  const k = 2 / (p + 1);
  for (let i = p; i < arr.length; i++) prev = arr[i] * k + prev * (1 - k);
  return prev;
};
let ema80;
// Live-chart shortcut only applies if the chart has an EMA(80) study plotted;
// otherwise this falls back to the (always-correct) manual calc below.
const maStudy = liveValues?.studies?.find(s => s.name === 'Moving Average Exponential');
if (maStudy?.values?.MA) {
  ema80 = parseFloat(maStudy.values.MA.replace(/,/g, ''));
} else {
  ema80 = n >= 80 ? emaFn(closes, 80) : null;
}
const prevEma80 = n >= 81 ? emaFn(closes.slice(0, -1), 80) : ema80;

// ── RSI 14 ────────────────────────────────────────────────────
const rsiCalc = (arr, p = 14) => {
  let g = 0, l = 0;
  for (let i = arr.length - p; i < arr.length; i++) {
    const d = arr[i] - arr[i - 1];
    if (d > 0) g += d; else l -= d;
  }
  const ag = g / p, al = l / p;
  return al === 0 ? 100 : 100 - (100 / (1 + ag / al));
};
const rsi     = rsiCalc(closes);
const prevRsi = rsiCalc(closes.slice(0, -1));

// ── MACD 12-26-9 ─────────────────────────────────────────────
let e12 = closes.slice(0, 12).reduce((a, b) => a + b, 0) / 12;
let e26 = closes.slice(0, 26).reduce((a, b) => a + b, 0) / 26;
const macdSeries = [];
for (let i = 26; i < n; i++) {
  e12 = closes[i] * (2/13) + e12 * (1 - 2/13);
  e26 = closes[i] * (2/27) + e26 * (1 - 2/27);
  macdSeries.push(e12 - e26);
}
const macd     = macdSeries.at(-1);
const prevMacd = macdSeries.at(-2);

// 9-period EMA of the MACD line = signal line (needed for a true MACD
// crossover per the "macd" rule in strategies.json, used below for FMCG/Consumer)
const emaSeries = (arr, p) => {
  const out = [];
  let prev = arr.slice(0, p).reduce((a, b) => a + b, 0) / p;
  out[p - 1] = prev;
  const k = 2 / (p + 1);
  for (let i = p; i < arr.length; i++) { prev = arr[i] * k + prev * (1 - k); out[i] = prev; }
  return out;
};
const macdSignalSeries = macdSeries.length >= 9 ? emaSeries(macdSeries, 9) : [];
const macdSignal       = macdSignalSeries.at(-1);
const prevMacdSignal   = macdSignalSeries.at(-2);

const swingLow30 = Math.min(...bars.slice(-30).map(b => b.low));
const prevClose  = closes.at(-2);

// ── Generic SMA(period) — for map-driven sma_5/sma_30/sma_80 overrides ─
const smaOf = (arr, p) => (arr.length >= p ? arr.slice(-p).reduce((a, b) => a + b, 0) / p : null);
const smaCurrent = p => smaOf(closes, p);
const smaPrev    = p => smaOf(closes.slice(0, -1), p);

// ── Bollinger Bands 20-2 (mean-reversion — the rule documented in
// strategies.json) — for map-driven bollinger_bands overrides ─────────
function bollingerOf(arr) {
  const period = 20, mult = 2;
  if (arr.length < period) return null;
  const slice = arr.slice(-period);
  const mean = slice.reduce((a, b) => a + b, 0) / period;
  const variance = slice.reduce((a, b) => a + (b - mean) ** 2, 0) / period;
  const sd = Math.sqrt(variance);
  return { middle: mean, upper: mean + mult * sd, lower: mean - mult * sd };
}
const bbNow  = bollingerOf(closes);
const bbPrev = bollingerOf(closes.slice(0, -1));

// ── Candlestick pattern detectors (today vs prior bars) — for map-driven
// bullish_engulfing / bullish_harami overrides. Ported from the detectors
// in backtest.sh; BUY-only here (see header note on why there is no SELL side).
const isRedBar   = b => b.close < b.open;
const isGreenBar = b => b.close > b.open;
const barBody    = b => Math.abs(b.close - b.open);

function detectBullishEngulfingLive() {
  if (n < 5) return false;
  const c = bars.at(-1), p = bars.at(-2);
  const downtrend = bars.at(-5).close > p.close;
  const engulfs = isRedBar(p) && isGreenBar(c) && c.open <= p.close && c.close >= p.open && barBody(c) > barBody(p);
  return downtrend && engulfs;
}

function detectBullishHaramiLive() {
  if (n < 2) return false;
  const c = bars.at(-1), p = bars.at(-2);
  const contained = isRedBar(p) && isGreenBar(c) && c.open >= p.close && c.close <= p.open;
  if (!contained) return false;
  const macdConfirm = macd != null && prevMacd != null && macd > prevMacd;
  const maConfirm    = ema80 != null && price > ema80;
  const rsiConfirm    = prevRsi < 30 && rsi >= 30;
  return macdConfirm || maConfirm || rsiConfirm;
}

let signal = 'NONE', strategy = '', target = 0, stop = 0, hold = '', reason = '';

// ══════════════════════════════════════════════════════════════
// MORNING MODE  (9:15 AM weekdays)
// ══════════════════════════════════════════════════════════════
if (mode === 'morning') {

  if (mapped) {
    // ── Priority 1: per-stock backtested override — see header note ──
    const tag = `${mapped.strategy_name} (mapped: ${mapped.backtest_return} over ${mapped.trades} trades)`;

    if (mapped.strategy_id === 'sma_5' || mapped.strategy_id === 'sma_30' || mapped.strategy_id === 'sma_80') {
      const period = mapped.strategy_id === 'sma_5' ? 5 : mapped.strategy_id === 'sma_30' ? 30 : 80;
      const smaNow = smaCurrent(period), smaPrevV = smaPrev(period);
      if (smaNow != null && smaPrevV != null && prevClose < smaPrevV && price >= smaNow) {
        signal = 'BUY'; strategy = `${mapped.strategy_name} Cross (mapped)`;
        target = price * 1.10; stop = smaNow; hold = 'Per backtest';
        reason = `Price crossed above ${mapped.strategy_name} ₹${smaNow.toFixed(1)} · ${tag}`;
      } else if (smaNow != null && smaPrevV != null && prevClose >= smaPrevV && price < smaNow) {
        signal = 'SELL'; strategy = `${mapped.strategy_name} Cross Down`;
        stop = smaNow; hold = 'Exit position';
        reason = `Price crossed below ${mapped.strategy_name} ₹${smaNow.toFixed(1)} — mapped exit rule`;
      }

    } else if (mapped.strategy_id === 'macd' && macdSignal != null && prevMacdSignal != null) {
      if (prevMacd <= prevMacdSignal && macd > macdSignal) {
        signal = 'BUY'; strategy = `MACD Cross (mapped)`;
        target = price * 1.10; stop = ema80 || price * 0.95; hold = 'Per backtest';
        reason = `MACD crossed above signal · ${tag}`;
      } else if (prevMacd >= prevMacdSignal && macd < macdSignal) {
        signal = 'SELL'; strategy = 'MACD Cross Down';
        hold = 'Exit position';
        reason = `MACD crossed below signal line — mapped exit rule`;
      }

    } else if (mapped.strategy_id === 'rsi_14') {
      if (prevRsi <= 30 && rsi > 30) {
        signal = 'BUY'; strategy = `RSI 14 Recovery (mapped)`;
        target = price * 1.10; stop = price * 0.95; hold = 'Per backtest';
        reason = `RSI crossed above 30 from oversold (${rsi.toFixed(1)}) · ${tag}`;
      } else if ((prevRsi < 70 && rsi >= 70) || (prevRsi >= 30 && rsi < 30)) {
        signal = 'SELL'; strategy = 'RSI 14 Exit';
        hold = 'Exit position';
        reason = `RSI ${rsi >= 70 ? 'reached overbought (≥70)' : 'reversed back below 30'} — mapped exit rule`;
      }

    } else if (mapped.strategy_id === 'bollinger_bands' && bbNow && bbPrev) {
      if (prevClose <= bbPrev.lower && price > prevClose) {
        signal = 'BUY'; strategy = `Bollinger Mean-Reversion (mapped)`;
        target = bbNow.middle; stop = bbNow.lower; hold = 'Per backtest';
        reason = `Touched lower band ₹${bbPrev.lower.toFixed(1)} and reversed · ${tag}`;
      } else if (prevClose > bbPrev.middle && price <= bbNow.middle) {
        signal = 'SELL'; strategy = 'Bollinger Middle-Band Exit';
        hold = 'Exit position';
        reason = `Price fell back to middle band ₹${bbNow.middle.toFixed(1)} — mapped exit rule`;
      }

    } else if (mapped.strategy_id === 'bullish_engulfing' && detectBullishEngulfingLive()) {
      signal = 'BUY'; strategy = `Bullish Engulfing (mapped)`;
      target = price * 1.05; stop = bars.at(-2).low; hold = '5 days (per strategy_selector.md)';
      reason = `Bullish engulfing candle confirmed · ${tag} — no SELL side (see header note)`;

    } else if (mapped.strategy_id === 'bullish_harami' && detectBullishHaramiLive()) {
      signal = 'BUY'; strategy = `Bullish Harami (mapped)`;
      target = price * 1.05; stop = bars.at(-2).low; hold = '5 days (per strategy_selector.md)';
      reason = `Bullish harami confirmed (MACD/EMA80/RSI) · ${tag} — no SELL side (see header note)`;
    }
    // else: no entry/exit condition fired today for the mapped strategy — WAIT,
    // deliberately not falling through to sector logic (the map is Priority 1)

  } else if (isFmcgConsumer && macdSignal != null && prevMacdSignal != null) {
    // ── Priority 2a: Sector fallback — FMCG/Consumer → MACD signal-line crossover ──
    // (2yr backtest: NESTLEIND MACD +22.7%/55.6% win rate vs EMA80 -11.1% —
    // see strategy_selector.md Sector Override. Based on one FMCG data point.)
    const macdCrossAbove = prevMacd <= prevMacdSignal && macd > macdSignal;
    const belowZero      = macd < 0 && macdSignal < 0;
    const rsiConfirm      = rsi > 30; // per strategy_selector.md — RSI recovery confirmation

    if (macdCrossAbove && belowZero && rsiConfirm) {
      signal   = 'BUY';
      strategy = 'MACD Cross (FMCG/Consumer)';
      target   = price * 1.10;
      stop     = ema80 || price * 0.95;
      hold     = '1-1.5 months';
      reason   = `MACD crossed above signal while both below zero · RSI ${rsi.toFixed(1)}>30 confirmed · sector: ${sector}`;
    } else if (macd > 0 && macd >= prevMacd && ema80 && price > ema80 && rsi < 75 && rsiConfirm) {
      signal   = 'BUY';
      strategy = 'MACD Positional (FMCG/Consumer)';
      target   = price * 1.10;
      stop     = ema80;
      hold     = '1-1.5 months';
      reason   = `MACD positive & rising above EMA80 ₹${ema80.toFixed(1)} · RSI ${rsi.toFixed(1)} confirmed · sector: ${sector}`;

    // Exit rule (strategies.json "macd"): sell when MACD crosses below signal
    } else if (prevMacd >= prevMacdSignal && macd < macdSignal) {
      signal   = 'SELL';
      strategy = 'MACD Cross Down (FMCG/Consumer)';
      hold     = 'Exit position';
      reason   = `MACD crossed below signal line · sector: ${sector} — exit rule per strategy_selector.md`;
    }

  } else {
    // 1. Fresh EMA80 crossover — strongest signal
    if (ema80 && prevClose < prevEma80 && price >= ema80) {
      signal   = 'BUY';
      strategy = 'EMA80 Fresh Cross';
      target   = price * 1.12;
      stop     = ema80;
      hold     = '2-4 months';
      reason   = `Fresh crossover above EMA80 ₹${ema80.toFixed(1)}`;

    // 2. EMA80 Positional — above EMA80 with MACD + RSI confirmation
    } else if (ema80 && price > ema80 && rsi < 75 && macd > 0 && macd >= prevMacd) {
      signal   = 'BUY';
      strategy = 'EMA80 Positional';
      target   = price * 1.12;
      stop     = ema80;
      hold     = '2-4 months';
      reason   = `Price ₹${price} above EMA80 ₹${ema80.toFixed(1)} · RSI ${rsi.toFixed(1)} · MACD ${macd.toFixed(2)} rising`;

    // 3. Intraday Momentum — RSI recovering from oversold with MACD curl
    } else if (ema80 && price > ema80 && prevRsi < 40 && rsi >= 40 && macd > prevMacd) {
      signal   = 'BUY';
      strategy = 'Intraday Momentum';
      target   = (price * 1.015).toFixed(1);
      stop     = (price * 0.992).toFixed(1);
      hold     = 'Today';
      reason   = `RSI crossed above 40 (${rsi.toFixed(1)}) · MACD curling up`;

    // Exit rule (strategy_selector.md): sell when price crosses below EMA80
    } else if (ema80 && prevClose >= prevEma80 && price < ema80) {
      signal   = 'SELL';
      strategy = 'EMA80 Cross Down';
      stop     = ema80;
      hold     = 'Exit position';
      reason   = `Price ₹${price} crossed below EMA80 ₹${ema80.toFixed(1)} — trend broken, exit rule per strategy_selector.md`;
    }
  }

// ══════════════════════════════════════════════════════════════
// EVENING MODE  (3:30 PM weekdays)
// ══════════════════════════════════════════════════════════════
} else if (mode === 'evening') {

  const today = bars.at(-1);
  const prev  = bars.at(-2);

  if (today && prev && ema80) {
    const range = today.high - today.low;

    // 1. Hammer candle at/near EMA80 support
    const isHammer = range > 0
      && (today.close - today.low)  / range > 0.6
      && (today.high  - today.close) / range < 0.25
      && today.low  <= ema80 * 1.01
      && today.close > ema80;

    // 2. Bullish Engulfing above EMA80
    const isBullEngulf = prev.close  < prev.open
      && today.close > today.open
      && today.open  <= prev.close
      && today.close >= prev.open
      && today.close > ema80;

    // 3. Swing reclaim — price just crossed back above EMA80 with MACD curl
    const isSwingReclaim = prev.close < ema80
      && today.close > ema80
      && macd > prevMacd;

    if (isHammer) {
      signal   = 'BUY'; strategy = 'Hammer @ EMA80';
      target   = price * 1.04; stop = today.low; hold = '3-7 days';
      reason   = `Hammer candle at EMA80 ₹${ema80.toFixed(1)} — reversal setup`;
    } else if (isBullEngulf) {
      signal   = 'BUY'; strategy = 'Bullish Engulfing';
      target   = price * 1.04; stop = today.low; hold = '3-7 days';
      reason   = `Bullish engulfing above EMA80 · open ₹${today.open} close ₹${today.close}`;
    } else if (isSwingReclaim) {
      signal   = 'BUY'; strategy = 'Swing Reclaim EMA80';
      target   = price * 1.05; stop = swingLow30; hold = '5-15 days';
      reason   = `Reclaimed EMA80 ₹${ema80.toFixed(1)} from below · MACD curling up`;
    }
  }

// ══════════════════════════════════════════════════════════════
// WEEKLY MODE  (Saturday 10 AM)
// Dow Theory: higher highs + higher lows on weekly bars
// ══════════════════════════════════════════════════════════════
} else if (mode === 'weekly') {

  const wBars  = bars.slice(-60);  // ~15 months of weekly bars
  const wHighs = wBars.map(b => b.high);
  const wLows  = wBars.map(b => b.low);

  // Pivot detection: local max/min in 5-bar window on each side
  const peaks   = [];
  const troughs = [];
  for (let i = 5; i < wBars.length - 5; i++) {
    if (wHighs[i] === Math.max(...wHighs.slice(i - 5, i + 6))) peaks.push(wHighs[i]);
    if (wLows[i]  === Math.min(...wLows.slice(i  - 5, i + 6))) troughs.push(wLows[i]);
  }

  const recentPeaks   = peaks.slice(-3);
  const recentTroughs = troughs.slice(-3);

  const higherHighs = recentPeaks.length   >= 2 && recentPeaks.every((v, i)   => i === 0 || v > recentPeaks[i - 1]);
  const higherLows  = recentTroughs.length >= 2 && recentTroughs.every((v, i) => i === 0 || v > recentTroughs[i - 1]);

  if (higherHighs && higherLows && ema80 && price > ema80) {
    const majorStop = recentTroughs.at(-1) ?? price * 0.95;
    signal   = 'BUY'; strategy = 'Dow Theory Bull';
    target   = price * 1.20; stop = majorStop; hold = '6-12 months';
    reason   = `HH: ${recentPeaks.map(v => v.toFixed(0)).join(' < ')} · HL: ${recentTroughs.map(v => v.toFixed(0)).join(' < ')}`;
  }
}

// ── Verbose output ────────────────────────────────────────────
const dl = '─'.repeat(54);
const signalIcon = signal === 'BUY' ? '🟢' : signal === 'SELL' ? '🔴' : '⏭ ';
console.log(`  ${dl}`);
console.log(`  Signal   : ${signalIcon} ${signal}`);
if (signal === 'BUY' || signal === 'SELL') {
  console.log(`  Strategy : ${strategy}`);
  console.log(`  Price    : ₹${price}${target ? '   Target: ₹' + parseFloat(target).toFixed(1) : ''}${stop ? '   Stop: ₹' + parseFloat(stop).toFixed(1) : ''}`);
  console.log(`  Hold     : ${hold}`);
  console.log(`  Reason   : ${reason}`);
}
if (ema80) console.log(`  EMA80    : ₹${ema80.toFixed(1)}   RSI: ${rsi.toFixed(1)}   MACD: ${macd?.toFixed(2) ?? 'N/A'}   Sector: ${sector}${isFmcgConsumer ? ' (MACD-preferred)' : ''}`);
console.log(`  Routing  : ${mapped ? `mapped → ${mapped.strategy_name} (${mapped.backtest_return}, n=${mapped.trades})` : 'sector-based fallback (no high-confidence map entry)'}`);
console.log(`  ${dl}`);

process.stdout.write([
  `__SIGNAL__:${signal}`,
  `__PRICE__:${price}`,
  `__TARGET__:${target ? parseFloat(target).toFixed(1) : ''}`,
  `__STOP__:${stop ? parseFloat(stop).toFixed(1) : ''}`,
  `__HOLD__:${hold}`,
  `__STRATEGY__:${strategy}`,
  `__RSI__:${rsi.toFixed(1)}`,
  `__REASON__:${reason}`,
  ''
].join('\n'));
JSEOF
  )

  $VERBOSE && echo "" && echo "$TECH_OUTPUT" | grep -v "^__"

  # ── Extract sentinels ────────────────────────────────────────
  SIGNAL=$(echo   "$TECH_OUTPUT" | grep "^__SIGNAL__:"   | cut -d: -f2)
  PRICE=$(echo    "$TECH_OUTPUT" | grep "^__PRICE__:"    | cut -d: -f2)
  TARGET=$(echo   "$TECH_OUTPUT" | grep "^__TARGET__:"   | cut -d: -f2)
  STOP=$(echo     "$TECH_OUTPUT" | grep "^__STOP__:"     | cut -d: -f2)
  HOLD=$(echo     "$TECH_OUTPUT" | grep "^__HOLD__:"     | cut -d: -f2)
  STRATEGY=$(echo "$TECH_OUTPUT" | grep "^__STRATEGY__:" | cut -d: -f2-)
  TECH_RSI=$(echo "$TECH_OUTPUT" | grep "^__RSI__:"      | cut -d: -f2)
  REASON=$(echo   "$TECH_OUTPUT" | grep "^__REASON__:"   | cut -d: -f2-)

  [ -z "$SIGNAL"   ] && SIGNAL="ERROR"
  [ -z "$PRICE"    ] && PRICE="—"
  [ -z "$TARGET"   ] && TARGET="—"
  [ -z "$STOP"     ] && STOP="—"

  # ── Progress line + per-signal notification ──────────────────
  if [ "$SIGNAL" = "BUY" ]; then
    printf "\r  [%3d/%d] %-14s  🟢 %-20s  ₹%s → ₹%s  SL:₹%s  %s\n" \
      "$IDX" "$SCAN_COUNT" "$STOCK" "$STRATEGY" "$PRICE" "$TARGET" "$STOP" "$HOLD"

    BUY_STOCKS+=("$STOCK")
    BUY_STRATEGIES+=("$STRATEGY")
    BUY_PRICES+=("$PRICE")
    BUY_TARGETS+=("$TARGET")
    BUY_STOPS+=("$STOP")
    BUY_HOLDS+=("$HOLD")

    notify_both \
      "🟢 $STOCK — $STRATEGY" \
      "Price: ₹$PRICE  |  Target: ₹$TARGET  |  Stop: ₹$STOP  |  Hold: $HOLD
Reason: $REASON"

  elif [ "$SIGNAL" = "SELL" ]; then
    printf "\r  [%3d/%d] %-14s  🔴 %-20s  ₹%s  SL:₹%s  %s\n" \
      "$IDX" "$SCAN_COUNT" "$STOCK" "$STRATEGY" "$PRICE" "$STOP" "$HOLD"

    SELL_STOCKS+=("$STOCK")
    SELL_STRATEGIES+=("$STRATEGY")
    SELL_PRICES+=("$PRICE")
    SELL_STOPS+=("$STOP")
    SELL_HOLDS+=("$HOLD")

    notify_both \
      "🔴 $STOCK — $STRATEGY" \
      "Price: ₹$PRICE  |  Hold: $HOLD
Reason: $REASON"

  else
    printf "\r  [%3d/%d] %-14s  ⏭  No signal (%s)\n" \
      "$IDX" "$SCAN_COUNT" "$STOCK" "${SIGNAL:-NONE}"
  fi
done

# ── Summary tables ───────────────────────────────────────────────
echo ""
MODE_UPPER=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')

if [ ${#BUY_STOCKS[@]} -eq 0 ] && [ ${#SELL_STOCKS[@]} -eq 0 ]; then
  echo "  No BUY or SELL signals triggered in this scan."
  echo ""
else
  if [ ${#BUY_STOCKS[@]} -gt 0 ]; then
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    printf "║  %-74s║\n" "BUY SIGNALS — $(date '+%d %b %Y  %H:%M')  [$MODE_UPPER MODE]"
    echo "╠══════════╦══════════════════════╦══════════╦══════════╦═══════════╦══════════╣"
    printf "║  %-8s  ║  %-18s  ║  %-8s  ║  %-8s  ║  %-9s  ║  %-8s  ║\n" \
      "STOCK" "STRATEGY" "PRICE" "TARGET" "STOP" "HOLD"
    echo "╠══════════╬══════════════════════╬══════════╬══════════╬═══════════╬══════════╣"

    for i in "${!BUY_STOCKS[@]}"; do
      printf "║  %-8s  ║  %-18s  ║  ₹%-7s  ║  ₹%-7s  ║  ₹%-8s  ║  %-8s  ║\n" \
        "${BUY_STOCKS[$i]}" "${BUY_STRATEGIES[$i]}" "${BUY_PRICES[$i]}" \
        "${BUY_TARGETS[$i]}" "${BUY_STOPS[$i]}" "${BUY_HOLDS[$i]}"
    done

    echo "╚══════════╩══════════════════════╩══════════╩══════════╩═══════════╩══════════╝"
    echo ""
  fi

  if [ ${#SELL_STOCKS[@]} -gt 0 ]; then
    echo "╔══════════════════════════════════════════════════════════════════╗"
    printf "║  %-66s║\n" "SELL SIGNALS — $(date '+%d %b %Y  %H:%M')  [$MODE_UPPER MODE]"
    echo "╠══════════╦══════════════════════╦══════════╦═══════════╦══════════╣"
    printf "║  %-8s  ║  %-18s  ║  %-8s  ║  %-9s  ║  %-8s  ║\n" \
      "STOCK" "STRATEGY" "PRICE" "STOP" "HOLD"
    echo "╠══════════╬══════════════════════╬══════════╬═══════════╬══════════╣"

    for i in "${!SELL_STOCKS[@]}"; do
      printf "║  %-8s  ║  %-18s  ║  ₹%-7s  ║  ₹%-8s  ║  %-8s  ║\n" \
        "${SELL_STOCKS[$i]}" "${SELL_STRATEGIES[$i]}" "${SELL_PRICES[$i]}" \
        "${SELL_STOPS[$i]}" "${SELL_HOLDS[$i]}"
    done

    echo "╚══════════╩══════════════════════╩══════════╩═══════════╩══════════╝"
    echo ""
  fi

  # ── Final summary notification (Mac + Telegram) ─────────────
  SIGNAL_LIST=""
  for i in "${!BUY_STOCKS[@]}"; do
    SIGNAL_LIST="${SIGNAL_LIST}🟢${BUY_STOCKS[$i]} (₹${BUY_PRICES[$i]} → ₹${BUY_TARGETS[$i]}) "
  done
  for i in "${!SELL_STOCKS[@]}"; do
    SIGNAL_LIST="${SIGNAL_LIST}🔴${SELL_STOCKS[$i]} (₹${SELL_PRICES[$i]}, exit) "
  done
  notify_both \
    "📊 Master Scan ($MODE) — ${#BUY_STOCKS[@]} Buy / ${#SELL_STOCKS[@]} Sell" \
    "$SIGNAL_LIST"
fi

echo "  🔔  Scan complete."
echo ""
