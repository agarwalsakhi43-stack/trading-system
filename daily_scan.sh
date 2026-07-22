#!/bin/bash
# daily_scan.sh — Multi-stock daily strategy scan
# Usage: ./daily_scan.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export TV_CLI="$SCRIPT_DIR/tradingview-mcp-jackson/src/cli/index.js"
export NOTIFY="$SCRIPT_DIR/notify.sh"
export STRATEGIES_FILE="$SCRIPT_DIR/strategies.json"
export SELECTOR_FILE="$SCRIPT_DIR/strategy_selector.md"
export STOCKS="NSE:RELIANCE NSE:TCS NSE:INFY NSE:HDFCBANK"
export DELAY="10"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║          DAILY STRATEGY SCAN                 ║"
printf "║  %-44s║\n" "$(date '+%A, %d %b %Y  %I:%M %p')"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Stocks  : $STOCKS"
echo "  Strategy: Auto-selected per strategy_selector.md"
echo "  Delay   : ${DELAY}s between stocks"
echo ""

# Pass everything via env vars; use quoted 'EOF' so bash doesn't touch the JS
node --input-type=module <<'JSEOF'
import { execSync } from 'child_process';
import { readFileSync } from 'fs';

const TV_CLI          = process.env.TV_CLI;
const NOTIFY          = process.env.NOTIFY;
const STRATEGIES_FILE = process.env.STRATEGIES_FILE;
const DELAY_S         = parseInt(process.env.DELAY || '10', 10);
const STOCKS_LIST     = process.env.STOCKS.trim().split(/\s+/).filter(Boolean);

// ── Load strategy files ───────────────────────────────────────
const strategies = JSON.parse(readFileSync(STRATEGIES_FILE, 'utf8'));

// ── Helpers ───────────────────────────────────────────────────
function run(cmd) {
  try {
    return JSON.parse(execSync(`node "${TV_CLI}" ${cmd}`, { timeout: 18000 }).toString());
  } catch { return null; }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

const smaFn = (arr, p) => arr.slice(-p).reduce((a, b) => a + b, 0) / p;

const emaFn = (arr, p) => {
  const k = 2 / (p + 1);
  let e = arr.slice(0, p).reduce((a, b) => a + b, 0) / p;
  for (let i = p; i < arr.length; i++) e = arr[i] * k + e * (1 - k);
  return e;
};

const rsiCalc = (arr, p = 14) => {
  let g = 0, l = 0;
  for (let i = arr.length - p; i < arr.length; i++) {
    const d = arr[i] - arr[i - 1];
    if (d > 0) g += d; else l -= d;
  }
  const ag = g / p, al = l / p;
  return al === 0 ? 100 : 100 - (100 / (1 + ag / al));
};

function notify(title, msg) {
  try { execSync(`"${NOTIFY}" "${title}" "${msg}"`, { timeout: 5000 }); }
  catch (e) { console.log(`  ⚠️  Notification failed: ${e.message}`); }
}

function emoji(signal) {
  if (signal === 'BUY')  return '🟢';
  if (signal === 'SELL') return '🔴';
  return '🟡';
}

// ── Per-stock analysis ────────────────────────────────────────
async function analyzeStock(symbol) {
  const ticker = symbol.split(':')[1] || symbol;
  const divider = '─'.repeat(46);

  console.log(`\n┌${divider}┐`);
  console.log(`│  ${symbol.padEnd(44)}│`);
  console.log(`└${divider}┘`);
  console.log(`  ⟳  Switching chart to ${symbol} on 1D…`);

  // Switch symbol and timeframe
  run(`symbol "${symbol}"`);
  await sleep(2500);
  run('timeframe 1D');
  await sleep(1000);

  // Fetch data
  const state      = run('state');
  const quote      = run('quote');
  const ohlcv      = run('ohlcv --bars 150');
  const liveValues = run('values');

  if (!state?.success || !quote?.success || !ohlcv?.success) {
    console.log(`  ❌  Failed to fetch data for ${symbol}`);
    return { symbol, ticker, signal: 'ERROR', price: null, sma80: null, rsi: null };
  }

  const price  = quote.close;
  const closes = ohlcv.bars.map(b => b.close);
  const bars   = ohlcv.bars;
  const n      = closes.length;

  // SMA 80: prefer live TradingView value, fall back to calculation
  let sma80;
  const maStudy = liveValues?.studies?.find(s => s.name === 'Moving Average');
  if (maStudy?.values?.MA) {
    sma80 = parseFloat(maStudy.values.MA.replace(/,/g, ''));
  } else {
    sma80 = n >= 80 ? smaFn(closes, 80) : null;
  }

  const sma50   = n >= 50 ? smaFn(closes, 50) : null;
  const rsi     = rsiCalc(closes);
  const prevRsi = rsiCalc(closes.slice(0, -1));

  // MACD (EMA12 - EMA26, signal = EMA9 of MACD)
  const macdSeries = [];
  let e12 = closes.slice(0, 12).reduce((a, b) => a + b, 0) / 12;
  let e26 = closes.slice(0, 26).reduce((a, b) => a + b, 0) / 26;
  for (let i = 26; i < n; i++) {
    e12 = closes[i] * (2 / 13) + e12 * (1 - 2 / 13);
    e26 = closes[i] * (2 / 27) + e26 * (1 - 2 / 27);
    macdSeries.push(e12 - e26);
  }
  const macd     = macdSeries.at(-1);
  const prevMacd = macdSeries.at(-2);

  // Crossover detection
  const prevCloses = closes.slice(0, -1);
  const prevSma80  = prevCloses.length >= 80 ? smaFn(prevCloses, 80) : sma80;

  // Bullish Engulfing on most recent candle
  const today     = bars.at(-1);
  const prevBar   = bars.at(-2);
  const engulfing = today.close > today.open
                 && prevBar.open > prevBar.close
                 && today.close > prevBar.open
                 && today.open  <= prevBar.close;

  // ── Strategy selector logic (per strategy_selector.md) ───────
  const isIndex = ['NIFTY', 'SENSEX', 'BANKNIFTY'].some(i => ticker.toUpperCase().includes(i));
  const sma80Strategy = strategies.strategies.find(s => s.id === 'sma_80');

  let strategy, signal, reasons = [];

  if (isIndex) {
    // Rule 1: Index → Dow Theory
    strategy = 'Dow Theory (Weekly chart)';
    signal   = 'WAIT';
    reasons.push('Index detected — check Weekly chart manually for Dow Theory structure');

  } else if (!sma80) {
    strategy = 'SMA 80';
    signal   = 'WAIT';
    reasons.push('Insufficient bar data to determine SMA 80');

  } else {
    // Rule 2: Stock + positional horizon → SMA 80
    strategy = `${sma80Strategy?.name} (${sma80Strategy?.hold_duration})`;

    const crossedAbove = prevCloses.at(-1) < prevSma80 && price > sma80;
    const crossedBelow = prevCloses.at(-1) > prevSma80 && price < sma80;

    if (crossedAbove) {
      signal = 'BUY';
      reasons.push(`Fresh crossover: price crossed ABOVE SMA 80 (₹${sma80.toFixed(1)}) today`);
    } else if (crossedBelow) {
      signal = 'SELL';
      reasons.push(`Fresh crossover: price crossed BELOW SMA 80 (₹${sma80.toFixed(1)}) today`);
    } else if (price > sma80) {
      signal = 'BUY';
      reasons.push(`Price (₹${price}) above SMA 80 (₹${sma80.toFixed(1)}) — uptrend intact`);
    } else {
      signal = 'WAIT';
      reasons.push(`Price (₹${price}) below SMA 80 (₹${sma80.toFixed(1)}) — avoid fresh longs`);
    }

    // Rule 7: RSI 14 always checked (Step 3 of selector)
    const rsiCrossed30 = prevRsi < 30 && rsi >= 30;
    if (rsiCrossed30)  reasons.push(`RSI crossed above 30 (now ${rsi.toFixed(1)}) ✅ oversold recovery — extra confirmation`);
    else if (rsi > 70) reasons.push(`RSI ${rsi.toFixed(1)} — overbought, caution on new buys ⚠️`);
    else               reasons.push(`RSI ${rsi.toFixed(1)} — neutral`);

    // MACD context
    if (macd >= 0 && macd > prevMacd)     reasons.push(`MACD (${macd.toFixed(2)}) above zero and rising — bullish ✅`);
    else if (macd >= 0)                   reasons.push(`MACD (${macd.toFixed(2)}) above zero`);
    else if (macd < 0 && macd > prevMacd) reasons.push(`MACD (${macd.toFixed(2)}) below zero but curling up — momentum building`);
    else                                  reasons.push(`MACD (${macd.toFixed(2)}) below zero`);

    // Bullish Engulfing bonus
    if (engulfing && signal === 'BUY')
      reasons.push('Bullish Engulfing pattern on latest candle ✅');
  }

  // Key levels
  const swingLow = Math.min(...bars.slice(-30).map(b => b.low));
  const nearRes  = bars.slice(-20).map(b => b.high)
                      .filter(h => h > price * 1.005)
                      .sort((a, b) => a - b)[0] || (price * 1.03);

  // Print per-stock report
  const em = emoji(signal);
  console.log(`\n  Strategy  : ${strategy}`);
  console.log(`  Signal    : ${em} ${signal}`);
  console.log(`  Price     : ₹${price}`);
  console.log(`  SMA 80    : ₹${sma80?.toFixed(1) ?? 'N/A'}`);
  if (sma50) console.log(`  SMA 50    : ₹${sma50.toFixed(1)}`);
  console.log(`  RSI 14    : ${rsi.toFixed(1)}`);
  console.log(`\n  Why:`);
  reasons.forEach(r => console.log(`    • ${r}`));
  console.log(`\n  Key Levels:`);
  console.log(`    Swing Low (Floor)  : ₹${swingLow.toFixed(1)}`);
  if (sma80) console.log(`    SMA 80 (Stop Loss) : ₹${sma80.toFixed(1)}`);
  console.log(`    Current Price      : ₹${price}`);
  console.log(`    Near Resistance    : ₹${nearRes.toFixed(1)}`);

  // Send colour-coded notification for every stock
  const title = `${em} ${ticker} — ${signal}`;
  const msg   = `₹${price} | SMA 80: ₹${sma80?.toFixed(1) ?? 'N/A'} | RSI: ${rsi.toFixed(0)} | ${strategy.split('(')[0].trim()}`;
  notify(title, msg);
  console.log(`\n  🔔  Notification sent: "${title}"`);

  return { symbol, ticker, signal, price, sma80, rsi };
}

// ── Main scan loop ────────────────────────────────────────────
const results = [];

for (let i = 0; i < STOCKS_LIST.length; i++) {
  const result = await analyzeStock(STOCKS_LIST[i]);
  results.push(result);

  if (i < STOCKS_LIST.length - 1) {
    console.log(`\n  ⏳  Waiting ${DELAY_S}s before next stock…\n`);
    await sleep(DELAY_S * 1000);
  }
}

// ── Summary table ─────────────────────────────────────────────
const W   = 58;
const bar = '═'.repeat(W);
console.log(`\n\n╔${bar}╗`);
console.log(`║${'  SCAN SUMMARY'.padEnd(W)}║`);
console.log(`╠${bar}╣`);
console.log(`║  ${'STOCK'.padEnd(12)} ${'SIGNAL'.padEnd(10)} ${'PRICE'.padEnd(12)} ${'SMA 80'.padEnd(10)} RSI  ║`);
console.log(`╠${bar}╣`);
for (const r of results) {
  const em    = emoji(r.signal);
  const sig   = `${em} ${r.signal}`.padEnd(12);
  const price = (r.price  ? `₹${r.price}`              : 'N/A').padEnd(12);
  const sma   = (r.sma80  ? `₹${r.sma80.toFixed(1)}`  : 'N/A').padEnd(10);
  const rsi   = (r.rsi    ? r.rsi.toFixed(1)           : 'N/A').padEnd(5);
  console.log(`║  ${r.ticker.padEnd(12)} ${sig} ${price} ${sma} ${rsi}║`);
}
console.log(`╚${bar}╝\n`);

// Final summary notification
const buys  = results.filter(r => r.signal === 'BUY').map(r => r.ticker).join(', ')  || 'None';
const sells = results.filter(r => r.signal === 'SELL').map(r => r.ticker).join(', ') || 'None';
const waits = results.filter(r => r.signal === 'WAIT').map(r => r.ticker).join(', ') || 'None';
notify(
  '📊 Daily Scan Complete',
  `🟢 Buy: ${buys} | 🔴 Sell: ${sells} | 🟡 Wait: ${waits}`
);
console.log(`  🔔  Final summary notification sent.\n`);
JSEOF
