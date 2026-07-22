#!/bin/bash
# backtest.sh — Historical strategy backtester (free Yahoo Finance OHLCV, no API key)
# Usage: ./backtest.sh SYMBOL[,SYMBOL2,...] STRATEGY[,STRATEGY2,...]
#   e.g. ./backtest.sh RELIANCE sma_80
#        ./backtest.sh RELIANCE,TCS,INFY,NESTLEIND,PIDILITIND sma_80,ema_80,macd,golden_cross
#        ./backtest.sh NESTLEIND,TCS rsi_14,bollinger_bands,bullish_engulfing
#
# Data source: query1.finance.yahoo.com/v8/finance/chart/SYMBOL.NS  (2y, 1d bars)
# Each symbol is fetched once and reused across all requested strategies.
# Strategy rules are read from strategies.json so this stays in sync with the
# same strategy definitions used elsewhere in this project.
#
# Supported strategy shapes (see strategies.json "indicator.type"):
#   SMA / EMA    — price crosses a single moving average (sma_80, ema_80, sma_5, sma_30)
#   crossover    — bullish two-MA crossover, i.e. golden_cross (alias: gold_cross)
#   MACD         — macd (26,12,9): buy when MACD crosses above signal while both are
#                  below zero; sell on any MACD-below-signal crossunder
#   RSI          — rsi_14: buy when RSI(14) crosses above 30 from below. EXIT RULE IS
#                  ASSUMED (strategies.json just says "overbought or reverses"): exits
#                  at RSI >= 70, OR RSI reverses back below 30 (recovery failed).
#   BB           — bollinger_bands: buy/sell rule is READ FROM strategies.json AT
#                  RUNTIME (see resolveBollingerRule below) — this lets a caller
#                  override the documented mean-reversion rule with a breakout
#                  variant via strategy.backtestOverride, without silently changing
#                  the project's canonical definition.
#   candlestick  — bullish_engulfing, morning_star, piercing_pattern, bullish_harami.
#                  Pattern trigger → enter at close of signal day → fixed 5-day hold
#                  (per strategy_selector.md), 5% target, stop at the pattern's own
#                  low — whichever hits first. Target/stop aren't numerically defined
#                  anywhere in the project; these are this script's own assumption.
#                  "Downtrend context" is approximated as net decline over the lookback
#                  window (not strictly monotonic red candles), to avoid a near-zero
#                  sample size over just 2 years of daily bars.
# Not yet implemented: Dow Theory, support/resistance, death_cross (short-only
# signal — no long-only equivalent).
#
# When more than one strategy is given, a side-by-side comparison matrix
# (Strategy Return % and Win Rate % per stock per strategy) is printed at the end.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STRATEGIES_FILE="$SCRIPT_DIR/strategies.json"

SYMBOLS_ARG="${1:-}"
STRATEGIES_ARG="${2:-}"
BB_RULE_ARG="${3:-}"   # optional: "breakout" (default if omitted) or "meanrev"

if [ -z "$SYMBOLS_ARG" ] || [ -z "$STRATEGIES_ARG" ]; then
  echo "Usage: ./backtest.sh SYMBOL[,SYMBOL2,...] STRATEGY[,STRATEGY2,...] [bollinger_rule]"
  echo "  e.g. ./backtest.sh RELIANCE,TCS sma_80,ema_80,macd,golden_cross"
  echo "       ./backtest.sh NESTLEIND rsi_14,bollinger_bands,bullish_engulfing,morning_star"
  echo "  bollinger_rule: 'breakout' (buy above upper, sell at middle — default) or"
  echo "                  'meanrev' (buy at lower band, sell at middle/upper — strategies.json's rule)"
  exit 1
fi

export SYMBOLS_ARG STRATEGIES_ARG STRATEGIES_FILE BB_RULE_ARG

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Strategy Backtester — Yahoo Finance (2y daily)  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

node --input-type=module <<'JSEOF'
import { execSync } from 'child_process';
import { readFileSync } from 'fs';

const SYMBOLS_ARG      = process.env.SYMBOLS_ARG;
const STRATEGIES_ARG   = process.env.STRATEGIES_ARG;
const STRATEGIES_FILE  = process.env.STRATEGIES_FILE;
const BB_RULE          = (process.env.BB_RULE_ARG || 'breakout').toLowerCase();

const norm = s => String(s).toLowerCase().replace(/[\s_-]/g, '');
const ALIASES = { goldcross: 'golden_cross', deathcross: 'death_cross' };

// ── Load & resolve strategies ──────────────────────────────────
const { strategies } = JSON.parse(readFileSync(STRATEGIES_FILE, 'utf8'));

function resolveStrategy(arg) {
  const n = norm(arg);
  const aliasId = ALIASES[n];
  return strategies.find(s =>
    norm(s.id) === n || norm(s.name) === n || (aliasId && s.id === aliasId)
  );
}

const CANDLESTICK_IDS = new Set(['bullish_engulfing', 'morning_star', 'piercing_pattern', 'bullish_harami']);

function classify(strategy) {
  const indType = strategy.indicator.type;
  const isMACD        = indType === 'MACD';
  const isSingleMA     = indType === 'SMA' || indType === 'EMA';
  const isCrossover    = indType === 'crossover' && strategy.signal !== 'bearish';
  const isBollinger    = indType === 'BB';
  const isRSI          = indType === 'RSI';
  const isCandlestick  = indType === 'candlestick' && CANDLESTICK_IDS.has(strategy.id);
  const supported = isMACD || isSingleMA || isCrossover || isBollinger || isRSI || isCandlestick;
  return { indType, isMACD, isSingleMA, isCrossover, isBollinger, isRSI, isCandlestick, supported };
}

const requestedIds = STRATEGIES_ARG.split(',').map(s => s.trim()).filter(Boolean);
const resolved = [];
for (const arg of requestedIds) {
  const strategy = resolveStrategy(arg);
  if (!strategy) {
    console.error(`❌  Strategy "${arg}" not found in strategies.json — skipping.`);
    console.error(`    Available: ${strategies.map(s => s.id).join(', ')}`);
    continue;
  }
  const info = classify(strategy);
  if (!info.supported) {
    console.error(`❌  "${strategy.name}" (${info.indType}) isn't implemented in backtest.sh yet — skipping.`);
    console.error(`    Not yet: Dow Theory, support/resistance, death_cross.`);
    continue;
  }
  resolved.push({ strategy, ...info });
}

if (resolved.length === 0) {
  console.error(`❌  No supported strategies to run.`);
  process.exit(1);
}

console.log(`  Strategies: ${resolved.map(r => r.strategy.name).join(', ')}`);
console.log(`  Window    : 2 years, daily bars`);
if (resolved.some(r => r.isBollinger)) {
  console.log(`  Bollinger rule: ${BB_RULE === 'meanrev' ? 'mean-reversion (buy lower band, sell mid/upper — strategies.json default)' : 'BREAKOUT (buy above upper band, sell at middle band — user-specified, differs from strategies.json)'}`);
}
console.log('');

// ── Fetch 2y daily OHLCV from Yahoo Finance ────────────────────
function fetchYahooDaily(symbol) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${symbol}.NS?range=2y&interval=1d`;
  try {
    const raw = execSync(
      `curl -s -L "${url}" -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" --max-time 30`,
      { timeout: 35000 }
    ).toString();
    const data   = JSON.parse(raw);
    const result = data?.chart?.result?.[0];
    if (!result || !result.timestamp) return null;

    const ts = result.timestamp;
    const q  = result.indicators.quote[0];
    const bars = [];
    for (let i = 0; i < ts.length; i++) {
      if (q.close[i] == null) continue; // skip bars with missing data
      bars.push({
        date:   new Date(ts[i] * 1000).toISOString().slice(0, 10),
        open:   q.open[i],
        high:   q.high[i],
        low:    q.low[i],
        close:  q.close[i],
        volume: q.volume[i],
      });
    }
    return bars;
  } catch {
    return null;
  }
}

// ── Indicators ──────────────────────────────────────────────────
function sma(closes, period) {
  const out = new Array(closes.length).fill(null);
  let sum = 0;
  for (let i = 0; i < closes.length; i++) {
    sum += closes[i];
    if (i >= period) sum -= closes[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

// EMA over a (possibly sparse, leading-null) series — used for price EMAs,
// the MACD signal line, and EMA80 (used as Bullish Harami's MA confirmation).
function ema(series, period) {
  const out = new Array(series.length).fill(null);
  const start = series.findIndex(v => v != null);
  if (start === -1) return out;
  const k = 2 / (period + 1);
  let prev = null, count = 0;
  for (let i = start; i < series.length; i++) {
    count++;
    if (count === period) {
      let sum = 0;
      for (let j = i - period + 1; j <= i; j++) sum += series[j];
      prev = sum / period;
      out[i] = prev;
    } else if (count > period) {
      prev = series[i] * k + prev * (1 - k);
      out[i] = prev;
    }
  }
  return out;
}

const getSeries = (closes, type, period) => (type === 'EMA' ? ema(closes, period) : sma(closes, period));

function stddevSeries(closes, period) {
  const out = new Array(closes.length).fill(null);
  for (let i = period - 1; i < closes.length; i++) {
    const slice = closes.slice(i - period + 1, i + 1);
    const mean = slice.reduce((a, b) => a + b, 0) / period;
    const variance = slice.reduce((a, b) => a + (b - mean) ** 2, 0) / period;
    out[i] = Math.sqrt(variance);
  }
  return out;
}

function bollingerBands(closes, period, mult) {
  const middle = sma(closes, period);
  const sd = stddevSeries(closes, period);
  const upper = closes.map((_, i) => (middle[i] != null && sd[i] != null) ? middle[i] + mult * sd[i] : null);
  const lower = closes.map((_, i) => (middle[i] != null && sd[i] != null) ? middle[i] - mult * sd[i] : null);
  return { middle, upper, lower };
}

// Wilder's RSI — standard rolling calculation (needed for a full daily series,
// not just a point-in-time snapshot like master_scan.sh's simpler version).
function rsiSeries(closes, period = 14) {
  const out = new Array(closes.length).fill(null);
  if (closes.length <= period) return out;
  let gainSum = 0, lossSum = 0;
  for (let i = 1; i <= period; i++) {
    const d = closes[i] - closes[i - 1];
    if (d > 0) gainSum += d; else lossSum -= d;
  }
  let avgGain = gainSum / period, avgLoss = lossSum / period;
  out[period] = avgLoss === 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
  for (let i = period + 1; i < closes.length; i++) {
    const d = closes[i] - closes[i - 1];
    const gain = d > 0 ? d : 0;
    const loss = d < 0 ? -d : 0;
    avgGain = (avgGain * (period - 1) + gain) / period;
    avgLoss = (avgLoss * (period - 1) + loss) / period;
    out[i] = avgLoss === 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
  }
  return out;
}

// ── Candlestick pattern detectors ────────────────────────────────
// Each returns { stopLow } if the pattern triggers AT index i, else null.
const isRed   = b => b.close < b.open;
const isGreen = b => b.close > b.open;
const body    = b => Math.abs(b.close - b.open);

function detectBullishEngulfing(bars, i) {
  if (i < 4) return null;
  const c = bars[i], p = bars[i - 1];
  const downtrend = bars[i - 4].close > bars[i - 1].close;
  const engulfs = isRed(p) && isGreen(c) && c.open <= p.close && c.close >= p.open && body(c) > body(p);
  return (downtrend && engulfs) ? { stopLow: Math.min(p.low, c.low) } : null;
}

function detectMorningStar(bars, i) {
  if (i < 5) return null;
  const c = bars[i], mid = bars[i - 1], red = bars[i - 2];
  const downtrend = bars[i - 5].close > bars[i - 2].close;
  const bigRed    = isRed(red) && body(red) > 0;
  const smallMid  = bigRed && body(mid) < body(red) * 0.4;
  const tradedLower = Math.max(mid.open, mid.close) < red.close; // softened "gap down" — daily NSE gaps are rare
  const bigGreen  = isGreen(c) && c.close > (red.open + red.close) / 2;
  return (downtrend && bigRed && smallMid && tradedLower && bigGreen)
    ? { stopLow: Math.min(red.low, mid.low, c.low) } : null;
}

function detectPiercingPattern(bars, i) {
  if (i < 4) return null;
  const c = bars[i], p = bars[i - 1];
  const downtrend = bars[i - 4].close > bars[i - 1].close;
  const piercing = isRed(p) && isGreen(c) && c.open < p.low && c.close > (p.open + p.close) / 2 && c.close < p.open;
  return (downtrend && piercing) ? { stopLow: Math.min(p.low, c.low) } : null;
}

// Bullish Harami needs same-day confirmation: MACD curling up, price above
// EMA80, or RSI turning up from oversold (any one of the three).
function detectBullishHarami(bars, i, ctx) {
  if (i < 1) return null;
  const c = bars[i], p = bars[i - 1];
  const contained = isRed(p) && isGreen(c) && c.open >= p.close && c.close <= p.open;
  if (!contained) return null;

  const macdConfirm = ctx.macdLine[i] != null && ctx.macdLine[i - 1] != null && ctx.macdLine[i] > ctx.macdLine[i - 1];
  const maConfirm    = ctx.ema80[i] != null && ctx.closes[i] > ctx.ema80[i];
  const rsiConfirm    = ctx.rsi[i - 1] != null && ctx.rsi[i] != null && ctx.rsi[i - 1] < 30 && ctx.rsi[i] >= 30;

  return (macdConfirm || maConfirm || rsiConfirm) ? { stopLow: Math.min(p.low, c.low) } : null;
}

const PATTERN_DETECTORS = {
  bullish_engulfing: (bars, i) => detectBullishEngulfing(bars, i),
  morning_star:      (bars, i) => detectMorningStar(bars, i),
  piercing_pattern:  (bars, i) => detectPiercingPattern(bars, i),
  bullish_harami:    (bars, i, ctx) => detectBullishHarami(bars, i, ctx),
};

// ── Backtest engines ─────────────────────────────────────────────

// Crossover-family engine (SMA/EMA vs price, two-MA crossover, MACD).
// Entry/exit executed at the close of the signal day (no slippage/costs modeled).
function runCrossoverBacktest(bars, strategy, info) {
  const closes = bars.map(b => b.close);
  const n = closes.length;

  let line1, line2, entryFilter = () => true;

  if (info.isMACD) {
    const { fast, slow, signal } = strategy.indicator;
    const fastEma    = ema(closes, fast);
    const slowEma    = ema(closes, slow);
    const macdLine   = closes.map((_, i) => (fastEma[i] != null && slowEma[i] != null) ? fastEma[i] - slowEma[i] : null);
    const signalLine = ema(macdLine, signal);
    line1 = macdLine;
    line2 = signalLine;
    entryFilter = i => macdLine[i] < 0 && signalLine[i] < 0; // "while both are below the zero line"
  } else if (info.isCrossover) {
    const parseMA = str => { const [t, p] = str.split('_'); return { type: t.toUpperCase() === 'SMA' ? 'SMA' : 'EMA', period: +p }; };
    const fastDef = parseMA(strategy.indicator.fast_ma);
    const slowDef = parseMA(strategy.indicator.slow_ma);
    line1 = getSeries(closes, fastDef.type, fastDef.period);
    line2 = getSeries(closes, slowDef.type, slowDef.period);
  } else {
    line1 = closes; // price line
    line2 = getSeries(closes, info.indType, strategy.indicator.period);
  }

  const trades = [];
  let position = null;

  for (let i = 1; i < n; i++) {
    if (line1[i] == null || line2[i] == null || line1[i - 1] == null || line2[i - 1] == null) continue;
    const crossAbove = line1[i - 1] <= line2[i - 1] && line1[i] > line2[i];
    const crossBelow = line1[i - 1] >= line2[i - 1] && line1[i] < line2[i];

    if (!position && crossAbove && entryFilter(i)) {
      position = { entryDate: bars[i].date, entryPrice: closes[i] };
    } else if (position && crossBelow) {
      const exitPrice = closes[i];
      const retPct = (exitPrice / position.entryPrice - 1) * 100;
      trades.push({ ...position, exitDate: bars[i].date, exitPrice, retPct });
      position = null;
    }
  }

  return finalizeBacktest(bars, closes, trades, position);
}

// Bollinger Bands. BB_RULE 'breakout' (default, user-specified this session):
// buy when price crosses above the upper band, sell when it falls back to the
// middle band. 'meanrev' (strategies.json's documented rule): buy when price
// touches/breaks the lower band and reverses, sell at middle/upper band.
function runBollingerBacktest(bars) {
  const closes = bars.map(b => b.close);
  const n = closes.length;
  const { middle, upper, lower } = bollingerBands(closes, 20, 2);

  const trades = [];
  let position = null;

  for (let i = 1; i < n; i++) {
    if (middle[i] == null || upper[i] == null || lower[i] == null) continue;

    if (BB_RULE === 'meanrev') {
      const touchedLowerAndReversed = closes[i - 1] <= lower[i - 1] && closes[i] > closes[i - 1] && lower[i - 1] != null;
      if (!position && touchedLowerAndReversed) {
        position = { entryDate: bars[i].date, entryPrice: closes[i] };
      } else if (position && closes[i] >= middle[i]) {
        const exitPrice = closes[i];
        trades.push({ ...position, exitDate: bars[i].date, exitPrice, retPct: (exitPrice / position.entryPrice - 1) * 100 });
        position = null;
      }
    } else {
      const crossAboveUpper = closes[i - 1] <= upper[i - 1] && closes[i] > upper[i];
      if (!position && crossAboveUpper) {
        position = { entryDate: bars[i].date, entryPrice: closes[i] };
      } else if (position && closes[i] <= middle[i]) {
        const exitPrice = closes[i];
        trades.push({ ...position, exitDate: bars[i].date, exitPrice, retPct: (exitPrice / position.entryPrice - 1) * 100 });
        position = null;
      }
    }
  }

  return finalizeBacktest(bars, closes, trades, position);
}

// RSI 14: buy when RSI crosses above 30 from below. Exit rule is an explicit
// assumption (strategies.json says "overbought zone (above 70) or reverses"):
// exits at RSI >= 70 (target reached) OR RSI reverses back below 30 (failed recovery).
function runRsiBacktest(bars) {
  const closes = bars.map(b => b.close);
  const n = closes.length;
  const rsi = rsiSeries(closes, 14);

  const trades = [];
  let position = null;

  for (let i = 1; i < n; i++) {
    if (rsi[i] == null || rsi[i - 1] == null) continue;
    const crossAbove30 = rsi[i - 1] <= 30 && rsi[i] > 30;
    const exitSignal    = rsi[i] >= 70 || (rsi[i - 1] >= 30 && rsi[i] < 30);

    if (!position && crossAbove30) {
      position = { entryDate: bars[i].date, entryPrice: closes[i] };
    } else if (position && exitSignal) {
      const exitPrice = closes[i];
      trades.push({ ...position, exitDate: bars[i].date, exitPrice, retPct: (exitPrice / position.entryPrice - 1) * 100 });
      position = null;
    }
  }

  return finalizeBacktest(bars, closes, trades, position);
}

// Candlestick patterns: trigger → enter at close of signal day → hold up to
// 5 trading days, exiting early on a 5% target or a stop at the pattern's low
// (checked via each subsequent day's high/low), whichever comes first.
// No overlapping trades — after an exit, scanning resumes from the next bar.
function runPatternBacktest(bars, strategy, ctx) {
  const closes = bars.map(b => b.close);
  const n = closes.length;
  const detect = PATTERN_DETECTORS[strategy.id];
  const HOLD_DAYS = 5, TARGET_PCT = 0.05;

  const trades = [];
  let i = 5; // need lookback room for the longest pattern (morning_star)

  while (i < n) {
    if (i > n - 2) break; // need at least 1 day of room to hold
    const pattern = detect(bars, i, ctx);
    if (pattern) {
      const entryPrice = closes[i];
      const entryDate  = bars[i].date;
      const target = entryPrice * (1 + TARGET_PCT);
      const stop   = pattern.stopLow;
      const lastJ  = Math.min(i + HOLD_DAYS, n - 1);

      let exitIdx = null, exitPrice = null;
      for (let j = i + 1; j <= lastJ; j++) {
        if (bars[j].low <= stop)   { exitIdx = j; exitPrice = stop;   break; }
        if (bars[j].high >= target) { exitIdx = j; exitPrice = target; break; }
      }
      if (exitIdx == null) { exitIdx = lastJ; exitPrice = closes[lastJ]; }

      trades.push({
        entryDate, entryPrice, exitDate: bars[exitIdx].date, exitPrice,
        retPct: (exitPrice / entryPrice - 1) * 100,
      });
      i = exitIdx + 1;
      continue;
    }
    i++;
  }

  return finalizeBacktest(bars, closes, trades, null);
}

function finalizeBacktest(bars, closes, trades, position) {
  const n = closes.length;
  let openPosition = null;
  if (position) {
    const lastClose = closes[n - 1];
    openPosition = {
      ...position,
      markDate: bars[n - 1].date,
      markPrice: lastClose,
      markRetPct: (lastClose / position.entryPrice - 1) * 100,
    };
  }
  const buyHoldRetPct = (closes[n - 1] / closes[0] - 1) * 100;
  return { trades, openPosition, buyHoldRetPct, firstDate: bars[0].date, lastDate: bars[n - 1].date };
}

function stats(trades) {
  if (trades.length === 0) {
    return { total: 0, winRate: null, avgWin: null, avgLoss: null, avgAll: null, best: null, worst: null, stratReturn: 0 };
  }
  const wins   = trades.filter(t => t.retPct > 0);
  const losses = trades.filter(t => t.retPct <= 0);
  const avg = arr => arr.reduce((a, b) => a + b, 0) / arr.length;
  const stratReturn = (trades.reduce((acc, t) => acc * (1 + t.retPct / 100), 1) - 1) * 100;
  return {
    total: trades.length,
    winRate: (wins.length / trades.length) * 100,
    avgWin: wins.length ? avg(wins.map(t => t.retPct)) : null,
    avgLoss: losses.length ? avg(losses.map(t => t.retPct)) : null,
    avgAll: avg(trades.map(t => t.retPct)),
    best: trades.reduce((m, t) => (t.retPct > m.retPct ? t : m)),
    worst: trades.reduce((m, t) => (t.retPct < m.retPct ? t : m)),
    stratReturn,
  };
}

const fmtPct = v => (v == null ? 'N/A' : (v >= 0 ? '+' : '') + v.toFixed(1) + '%');
const pad  = (s, w) => String(s).padEnd(w);
const padN = (s, w) => String(s).padStart(w);

// ── Fetch each symbol once ──────────────────────────────────────
const symbols = SYMBOLS_ARG.split(',').map(s => s.trim().toUpperCase()).filter(Boolean);
const barsBySymbol = {};
const ctxBySymbol = {}; // precomputed EMA80/RSI/MACD, for bullish_harami confirmation

for (const symbol of symbols) {
  process.stdout.write(`  ⟳  ${symbol}: fetching 2y daily data from Yahoo Finance…`);
  const bars = fetchYahooDaily(symbol);
  if (!bars || bars.length < 30) {
    console.log(`  ❌  no data (check symbol — Yahoo expects NSE format, e.g. RELIANCE → RELIANCE.NS)`);
    barsBySymbol[symbol] = null;
    continue;
  }
  console.log(`  ✅  ${bars.length} bars (${bars[0].date} → ${bars[bars.length - 1].date})`);
  barsBySymbol[symbol] = bars;

  const closes = bars.map(b => b.close);
  const fastEma = ema(closes, 12), slowEma = ema(closes, 26);
  const macdLine = closes.map((_, i) => (fastEma[i] != null && slowEma[i] != null) ? fastEma[i] - slowEma[i] : null);
  ctxBySymbol[symbol] = { closes, ema80: ema(closes, 80), rsi: rsiSeries(closes, 14), macdLine };
}
console.log('');

const symbolColWidth = Math.max(8, ...symbols.map(s => s.length + 1));

// ── Run every strategy against every symbol ─────────────────────
// matrix[strategyId][symbol] = row stats (or {error:true})
const matrix = {};

for (const { strategy, ...info } of resolved) {
  const rows = [];
  for (const symbol of symbols) {
    const bars = barsBySymbol[symbol];
    if (!bars) { rows.push({ symbol, error: true }); continue; }

    let result;
    if (info.isCandlestick) result = runPatternBacktest(bars, strategy, ctxBySymbol[symbol]);
    else if (info.isBollinger) result = runBollingerBacktest(bars);
    else if (info.isRSI) result = runRsiBacktest(bars);
    else result = runCrossoverBacktest(bars, strategy, info);

    const s = stats(result.trades);
    rows.push({ symbol, ...s, ...result });
  }
  matrix[strategy.id] = rows;

  // ── Per-strategy table ─────────────────────────────────────
  const cols = [
    ['Symbol', symbolColWidth], ['Trades', 7], ['Win %', 7], ['AvgWin', 8], ['AvgLoss', 8],
    ['Best', 8], ['Worst', 8], ['Strategy', 9], ['BuyHold', 8], ['Edge', 8],
  ];
  const entryText = info.isBollinger
    ? (BB_RULE === 'meanrev' ? strategy.entry : 'Buy when price crosses above the upper band (breakout — overrides strategies.json default)')
    : strategy.entry;
  console.log(`  Strategy: ${strategy.name}  |  ${entryText}`);
  console.log('');
  let header = '  ' + cols.map(([name, w]) => pad(name, w)).join(' ');
  console.log(header);
  console.log('  ' + '─'.repeat(header.length - 2));

  for (const r of rows) {
    if (r.error) {
      console.log('  ' + pad(r.symbol, symbolColWidth) + ' ' + 'no data / symbol not found on Yahoo Finance');
      continue;
    }
    const edge = r.stratReturn - r.buyHoldRetPct;
    const line = [
      pad(r.symbol, symbolColWidth),
      padN(r.total, 7),
      padN(r.winRate == null ? 'N/A' : r.winRate.toFixed(1) + '%', 7),
      padN(fmtPct(r.avgWin), 8),
      padN(fmtPct(r.avgLoss), 8),
      padN(r.best ? fmtPct(r.best.retPct) : 'N/A', 8),
      padN(r.worst ? fmtPct(r.worst.retPct) : 'N/A', 8),
      padN(fmtPct(r.stratReturn), 9),
      padN(fmtPct(r.buyHoldRetPct), 8),
      padN((edge >= 0 ? '+' : '') + edge.toFixed(1) + '%', 8),
    ].join(' ');
    console.log('  ' + line);
  }
  console.log('');

  for (const r of rows) {
    if (r.error || r.total === 0) continue;
    console.log(`  ${r.symbol} — ${r.total} closed trade(s):`);
    for (const t of r.trades) {
      const mark = t.retPct >= 0 ? '✅' : '❌';
      console.log(`      ${mark} ${t.entryDate} @ ₹${t.entryPrice.toFixed(2)}  →  ${t.exitDate} @ ₹${t.exitPrice.toFixed(2)}   ${fmtPct(t.retPct)}`);
    }
    if (r.openPosition) {
      console.log(`      ⏳ OPEN: entered ${r.openPosition.entryDate} @ ₹${r.openPosition.entryPrice.toFixed(2)}, ` +
        `still open as of ${r.openPosition.markDate} @ ₹${r.openPosition.markPrice.toFixed(2)} (${fmtPct(r.openPosition.markRetPct)} unrealized, not counted in stats above)`);
    }
    console.log('');
  }
}

// ── Cross-strategy comparison matrix ────────────────────────────
if (resolved.length > 1) {
  const stratNames = resolved.map(r => r.strategy.name);
  const stratColWidth = Math.max(9, ...stratNames.map(n => n.length + 1));

  console.log('═'.repeat(66));
  console.log('  STRATEGY COMPARISON — Return % by stock');
  console.log('═'.repeat(66));
  console.log('');
  let header = '  ' + pad('Symbol', symbolColWidth) + ' ' +
    resolved.map(r => pad(r.strategy.name, stratColWidth)).join(' ') + ' ' + pad('BuyHold', stratColWidth) + ' ' + 'Best Strategy';
  console.log(header);
  console.log('  ' + '─'.repeat(header.length - 2));

  for (const symbol of symbols) {
    const cells = resolved.map(r => matrix[r.strategy.id].find(row => row.symbol === symbol));
    if (cells.some(c => c.error)) {
      console.log('  ' + pad(symbol, symbolColWidth) + ' no data');
      continue;
    }
    const returns = cells.map(c => c.stratReturn);
    const buyHold = cells[0].buyHoldRetPct; // same for every strategy (same symbol/window)
    const bestIdx = returns.reduce((best, v, i) => (v > returns[best] ? i : best), 0);
    const bestLabel = `${stratNames[bestIdx]} (${fmtPct(returns[bestIdx])})`;

    const line = '  ' + pad(symbol, symbolColWidth) + ' ' +
      returns.map(v => pad(fmtPct(v), stratColWidth)).join(' ') + ' ' +
      pad(fmtPct(buyHold), stratColWidth) + ' ' + bestLabel;
    console.log(line);
  }
  console.log('');

  console.log('  STRATEGY COMPARISON — Win Rate % by stock');
  console.log('');
  const winRateHeader = '  ' + pad('Symbol', symbolColWidth) + ' ' +
    resolved.map(r => pad(r.strategy.name, stratColWidth)).join(' ');
  console.log(winRateHeader);
  console.log('  ' + '─'.repeat(winRateHeader.length - 2));
  for (const symbol of symbols) {
    const cells = resolved.map(r => matrix[r.strategy.id].find(row => row.symbol === symbol));
    if (cells.some(c => c.error)) {
      console.log('  ' + pad(symbol, symbolColWidth) + ' no data');
      continue;
    }
    const line = '  ' + pad(symbol, symbolColWidth) + ' ' +
      cells.map(c => pad(c.winRate == null ? 'N/A' : c.winRate.toFixed(1) + '%', stratColWidth)).join(' ');
    console.log(line);
  }
  console.log('');

  console.log('  STRATEGY COMPARISON — Avg Return % per Trade by stock');
  console.log('');
  console.log(winRateHeader);
  console.log('  ' + '─'.repeat(winRateHeader.length - 2));
  for (const symbol of symbols) {
    const cells = resolved.map(r => matrix[r.strategy.id].find(row => row.symbol === symbol));
    if (cells.some(c => c.error)) {
      console.log('  ' + pad(symbol, symbolColWidth) + ' no data');
      continue;
    }
    const line = '  ' + pad(symbol, symbolColWidth) + ' ' +
      cells.map(c => pad(c.avgAll == null ? 'N/A' : fmtPct(c.avgAll), stratColWidth)).join(' ');
    console.log(line);
  }
  console.log('');
}

console.log('  Note: entries/exits execute at the close of the signal day (candlestick');
console.log('  patterns exit intraday on target/stop touch); no brokerage, slippage, or');
console.log('  taxes are modeled. "Edge" = Strategy Return − Buy&Hold Return.');
console.log('');
JSEOF
