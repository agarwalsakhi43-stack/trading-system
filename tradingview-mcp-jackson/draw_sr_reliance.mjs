/**
 * draw_sr_reliance.mjs
 * Switches to NSE:RELIANCE, fetches 300 daily bars,
 * detects pivot-based S/R levels, and draws horizontal lines.
 */

import { evaluate, getChartApi, disconnect } from './src/connection.js';

// ─── helpers ───────────────────────────────────────────────────────────────

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function setSymbol(sym) {
  const api = await getChartApi();
  await evaluate(`${api}.setSymbol('${sym}', {})`);
  await sleep(3000);
}

async function setTimeframe(tf) {
  const api = await getChartApi();
  await evaluate(`${api}.setResolution('${tf}', {})`);
  await sleep(2000);
}

async function getOHLCV(count = 300) {
  const barsPath = `window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries().bars()`;
  const result = await evaluate(`
    (function(){
      var bars = ${barsPath};
      if (!bars || typeof bars.lastIndex !== 'function') return null;
      var end   = bars.lastIndex();
      var start = Math.max(bars.firstIndex(), end - ${count} + 1);
      var out = [];
      for (var i = start; i <= end; i++) {
        var v = bars.valueAt(i);
        if (v) out.push({ time: v[0], open: v[1], high: v[2], low: v[3], close: v[4], volume: v[5] || 0 });
      }
      return out;
    })()
  `);
  return result || [];
}

/** Detect pivot highs and lows using a rolling window */
function detectPivots(bars, lookback = 5) {
  const highs = [];
  const lows  = [];
  for (let i = lookback; i < bars.length - lookback; i++) {
    const h = bars[i].high;
    const l = bars[i].low;
    let isPH = true, isPL = true;
    for (let j = i - lookback; j <= i + lookback; j++) {
      if (j === i) continue;
      if (bars[j].high >= h) isPH = false;
      if (bars[j].low  <= l) isPL = false;
    }
    if (isPH) highs.push({ price: h, time: bars[i].time, idx: i });
    if (isPL) lows.push({ price: l, time: bars[i].time, idx: i });
  }
  return { highs, lows };
}

/** Cluster nearby levels within tolerance%. Returns ALL clusters sorted by count desc. */
function clusterLevels(points, tolerance = 0.012) {
  const clusters = [];
  for (const p of points) {
    let found = false;
    for (const c of clusters) {
      if (Math.abs(c.price - p.price) / c.price < tolerance) {
        c.price = (c.price * c.count + p.price) / (c.count + 1);
        c.count++;
        c.lastTime = Math.max(c.lastTime, p.time);
        found = true;
        break;
      }
    }
    if (!found) clusters.push({ price: p.price, count: 1, lastTime: p.time });
  }
  return clusters.sort((a, b) => b.count - a.count);
}

async function drawHLine(price, time, overrides) {
  const api = await getChartApi();
  const ovStr = JSON.stringify(overrides);
  await evaluate(`
    ${api}.createShape(
      { time: ${time}, price: ${price} },
      { shape: 'horizontal_line', overrides: ${ovStr} }
    )
  `);
  await sleep(150);
}

// ─── main ───────────────────────────────────────────────────────────────────

(async () => {
  try {
    console.log('Switching to NSE:RELIANCE …');
    await setSymbol('NSE:RELIANCE');

    console.log('Setting Daily timeframe …');
    await setTimeframe('D');

    console.log('Clearing existing drawings …');
    const api = await getChartApi();
    await evaluate(`${api}.removeAllShapes()`);
    await sleep(500);

    console.log('Fetching 300 bars …');
    const bars = await getOHLCV(300);
    if (!bars.length) throw new Error('No OHLCV data returned');
    console.log(`Got ${bars.length} bars. Latest close: ${bars[bars.length-1]?.close}`);

    // Use the latest bar's time as anchor for all horizontal lines
    const latestTime = bars[bars.length - 1].time;

    const { highs, lows } = detectPivots(bars, 5);
    console.log(`Found ${highs.length} pivot highs, ${lows.length} pivot lows`);

    const currentPrice = bars[bars.length - 1].close;
    console.log(`Current price: ${currentPrice}`);
    console.log(`All pivot lows: ${lows.map(l => l.price.toFixed(0)).join(', ')}`);
    console.log(`All pivot highs: ${highs.map(h => h.price.toFixed(0)).join(', ')}`);

    // Cluster all pivots, then filter above/below price, take top 6 each
    const allHighClusters = clusterLevels(highs, 0.012);
    const allLowClusters  = clusterLevels(lows,  0.012);

    const resistance = allHighClusters
      .filter(l => l.price > currentPrice)
      .slice(0, 6)
      .sort((a, b) => a.price - b.price);   // nearest first

    const support = allLowClusters
      .filter(l => l.price < currentPrice)
      .slice(0, 6)
      .sort((a, b) => b.price - a.price);   // nearest first

    console.log('\n=== SUPPORT LEVELS ===');
    for (const s of support) console.log(`  ₹${s.price.toFixed(2)}  (touches: ${s.count})`);

    console.log('\n=== RESISTANCE LEVELS ===');
    for (const r of resistance) console.log(`  ₹${r.price.toFixed(2)}  (touches: ${r.count})`);

    console.log('\nDrawing resistance lines (red) …');
    for (const r of resistance) {
      await drawHLine(r.price, latestTime, {
        linecolor: '#FF3B30',
        linewidth: r.count >= 3 ? 2 : 1,
        linestyle: 0,
        showLabel: true,
        text: `R ₹${Math.round(r.price)}`,
        textcolor: '#FF3B30',
        fontsize: 12,
        extendLeft: false,
        extendRight: true,
      });
      console.log(`  Drew R @ ${r.price.toFixed(2)}`);
    }

    console.log('\nDrawing support lines (green) …');
    for (const s of support) {
      await drawHLine(s.price, latestTime, {
        linecolor: '#34C759',
        linewidth: s.count >= 3 ? 2 : 1,
        linestyle: 0,
        showLabel: true,
        text: `S ₹${Math.round(s.price)}`,
        textcolor: '#34C759',
        fontsize: 12,
        extendLeft: false,
        extendRight: true,
      });
      console.log(`  Drew S @ ${s.price.toFixed(2)}`);
    }

    console.log('\nDone. All S/R lines drawn on chart.');
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  } finally {
    await disconnect();
  }
})();
