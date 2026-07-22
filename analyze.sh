#!/bin/bash
# analyze.sh — Strategy analysis for any stock on TradingView
# Usage: ./analyze.sh [symbol]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TV_CLI="$SCRIPT_DIR/tradingview-mcp-jackson/src/cli/index.js"
NOTIFY="$SCRIPT_DIR/notify.sh"

SYMBOL="${1:-}"

if [ -n "$SYMBOL" ]; then
  echo "Switching chart to $SYMBOL..."
  node "$TV_CLI" symbol "$SYMBOL" > /dev/null 2>&1
  sleep 2
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STRATEGY ANALYSIS ENGINE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

node --input-type=module <<EOF
import { execSync } from 'child_process';

const TV_CLI = "${TV_CLI}";
const NOTIFY = "${NOTIFY}";

function run(cmd) {
  try { return JSON.parse(execSync(\`node "\${TV_CLI}" \${cmd}\`, { timeout: 15000 }).toString()); }
  catch { return null; }
}

// ── 1. Fetch all data in parallel ─────────────────────────────
const [state, quote, ohlcv, liveValues] = await Promise.all([
  Promise.resolve(run('state')),
  Promise.resolve(run('quote')),
  Promise.resolve(run('ohlcv --bars 150')),
  Promise.resolve(run('values')),
]);

if (!state?.success || !quote?.success || !ohlcv?.success) {
  console.error('❌  Could not fetch chart data. Is TradingView connected?');
  process.exit(1);
}

const symbol  = state.symbol;
const ticker  = symbol.split(':')[1] || symbol;
const price   = quote.close;
const closes  = ohlcv.bars.map(b => b.close);
const bars    = ohlcv.bars;
const n       = closes.length;

// ── 2. Get SMA 80 — prefer live TV value, fall back to calc ───
const ema = (arr, p) => {
  const k = 2/(p+1);
  let e = arr.slice(0,p).reduce((a,b)=>a+b,0)/p;
  for (let i=p; i<arr.length; i++) e = arr[i]*k + e*(1-k);
  return e;
};
const smaCalc = (arr, p) => arr.slice(-p).reduce((a,b)=>a+b,0) / p;

// Pull live SMA 80 from TradingView values (the MA on the chart)
let sma80;
const maStudy = liveValues?.studies?.find(s => s.name === 'Moving Average');
if (maStudy?.values?.MA) {
  sma80 = parseFloat(maStudy.values.MA.replace(/,/g, ''));
} else {
  sma80 = n >= 80 ? smaCalc(closes, 80) : null;
}

const sma50  = n >= 50 ? smaCalc(closes, 50)  : null;
const ema12  = ema(closes, 12);
const ema26  = ema(closes, 26);
const macd   = ema12 - ema26;

// MACD signal line (EMA 9 of MACD values across recent bars)
const macdHistory = [];
let e12 = closes.slice(0,12).reduce((a,b)=>a+b,0)/12;
let e26 = closes.slice(0,26).reduce((a,b)=>a+b,0)/26;
for (let i=26; i<n; i++) {
  e12 = closes[i]*(2/13) + e12*(1-2/13);
  e26 = closes[i]*(2/27) + e26*(1-2/27);
  macdHistory.push(e12 - e26);
}
const signalLine = ema(macdHistory, 9);
const prevMacd   = macdHistory.at(-2);

// RSI 14
const calcRsi = (arr, p=14) => {
  let g=0, l=0;
  for (let i=arr.length-p; i<arr.length; i++) {
    const d = arr[i] - arr[i-1];
    if (d>0) g+=d; else l-=d;
  }
  const ag=g/p, al=l/p;
  return al===0 ? 100 : 100 - (100/(1+ag/al));
};
const rsi     = calcRsi(closes);
const prevRsi = calcRsi(closes.slice(0,-1));

// Previous bar SMA 80 (recalc from prior closes)
const prevCloses = closes.slice(0, -1);
const prevSma80  = prevCloses.length >= 80 ? smaCalc(prevCloses, 80) : sma80;

// Last 2 candles for pattern check
const today = bars.at(-1);
const prev  = bars.at(-2);

// ── 3. Strategy selector ──────────────────────────────────────
const isIndex = ['NIFTY','SENSEX','BANKNIFTY'].some(i => ticker.toUpperCase().includes(i));

let strategy, signal, reason = [];

if (isIndex) {
  strategy = 'Dow Theory (Weekly chart)';
  signal   = 'MANUAL CHECK';
  reason.push('Index detected — check Weekly chart for higher highs/lows pattern manually');

} else if (sma80 === null) {
  strategy = 'SMA 80';
  signal   = 'INSUFFICIENT DATA';
  reason.push('Not enough bars to calculate SMA 80');

} else {
  strategy = 'SMA 80 — Positional (6–9 months)';

  const crossedAbove = prevCloses.at(-1) < prevSma80 && price > sma80;
  const crossedBelow = prevCloses.at(-1) > prevSma80 && price < sma80;
  const aboveSma80   = price > sma80;

  if (crossedAbove) {
    signal = 'BUY';
    reason.push(\`Price crossed ABOVE SMA 80 (₹\${sma80.toFixed(1)}) today — fresh entry signal\`);
  } else if (crossedBelow) {
    signal = 'SELL';
    reason.push(\`Price crossed BELOW SMA 80 (₹\${sma80.toFixed(1)}) today — exit signal\`);
  } else if (aboveSma80) {
    signal = 'BUY';
    reason.push(\`Price (₹\${price}) is above SMA 80 (₹\${sma80.toFixed(1)}) — uptrend intact, hold/add\`);
  } else {
    signal = 'WAIT';
    reason.push(\`Price (₹\${price}) is below SMA 80 (₹\${sma80.toFixed(1)}) — avoid fresh longs\`);
  }

  // RSI confirmation (Step 3)
  const rsiCrossed30 = prevRsi < 30 && rsi >= 30;
  if (rsiCrossed30)  reason.push(\`RSI crossed above 30 (now \${rsi.toFixed(1)}) — oversold recovery ✅ extra confirmation\`);
  else if (rsi > 70) reason.push(\`RSI \${rsi.toFixed(1)} — overbought ⚠️  caution on fresh buys\`);
  else               reason.push(\`RSI \${rsi.toFixed(1)} — neutral\`);

  // MACD note (Step 4)
  if (macd < 0 && macd > prevMacd)  reason.push(\`MACD (\${macd.toFixed(2)}) below zero but curling up — momentum building\`);
  else if (macd < 0)                 reason.push(\`MACD (\${macd.toFixed(2)}) below zero — not yet confirmed\`);
  else if (macd > 0 && macd > signalLine) reason.push(\`MACD (\${macd.toFixed(2)}) above zero and above signal — bullish ✅\`);
  else                               reason.push(\`MACD (\${macd.toFixed(2)}) above zero\`);

  // Bullish Engulfing bonus
  const engulfing = today.close > today.open && prev.open > prev.close &&
                    today.close > prev.open  && today.open <= prev.close;
  if (engulfing && (signal === 'BUY'))
    reason.push('Bullish Engulfing pattern on latest candle — adds short-term conviction ✅');
}

// ── 4. Key levels ─────────────────────────────────────────────
const swingLow  = Math.min(...bars.slice(-30).map(b => b.low));
const nearRes   = bars.slice(-20).map(b=>b.high).filter(h=>h>price*1.005).sort((a,b)=>a-b)[0]
                  || (price * 1.03);

// ── 5. Print report ───────────────────────────────────────────
const hr = '━'.repeat(44);
console.log(\`\n\${hr}\`);
console.log(\`  \${symbol}  |  ₹\${price}  |  \${state.resolution} chart\`);
console.log(hr);
console.log(\`\n  STRATEGY : \${strategy}\`);
console.log(\`  SIGNAL   : \${signal}\`);
console.log(\`\n  WHY:\`);
reason.forEach(r => console.log(\`    • \${r}\`));
console.log(\`\n  KEY LEVELS:\`);
if (sma80) console.log(\`    SMA 80 (Stop Loss) : ₹\${sma80.toFixed(1)}\`);
if (sma50) console.log(\`    SMA 50             : ₹\${sma50.toFixed(1)}\`);
console.log(\`    Swing Low (Floor)  : ₹\${swingLow.toFixed(1)}\`);
console.log(\`    Current Price      : ₹\${price}\`);
console.log(\`    Near Resistance    : ₹\${nearRes.toFixed(1)}\`);
console.log(\`\n\${hr}\n\`);

// ── 6. Notify if Buy or Sell ──────────────────────────────────
if (signal === 'BUY' || signal === 'SELL') {
  const title = \`\${ticker} — \${signal} Signal\`;
  const msg   = \`\${signal} at ₹\${price} | SMA 80: ₹\${sma80?.toFixed(1)} | RSI: \${rsi.toFixed(0)}\`;
  try {
    execSync(\`"\${NOTIFY}" "\${title}" "\${msg}"\`, { timeout: 5000 });
    console.log(\`  🔔  Notification fired: "\${title}"\`);
    console.log(\`      "\${msg}"\`);
  } catch(e) {
    console.log(\`  ⚠️   Notification failed: \${e.message}\`);
  }
} else {
  console.log(\`  ℹ️   Signal is \${signal} — notification not triggered\`);
}
console.log('');
EOF
