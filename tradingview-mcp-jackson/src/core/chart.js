/**
 * Core chart control logic.
 */
import { evaluate, evaluateAsync, getClient, KNOWN_PATHS } from '../connection.js';
import { waitForChartReady } from '../wait.js';
import { safeDrawSRLevels } from './drawing.js';
import { getOhlcv } from './data.js';

const CHART_API = 'window.TradingViewApi._activeChartWidgetWV.value()';

export async function getState() {
  const state = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var studies = [];
      try {
        var allStudies = chart.getAllStudies();
        studies = allStudies.map(function(s) {
          return { id: s.id, name: s.name || s.title || 'unknown' };
        });
      } catch(e) {}
      return {
        symbol: chart.symbol(),
        resolution: chart.resolution(),
        chartType: chart.chartType(),
        studies: studies,
      };
    })()
  `);
  return { success: true, ...state };
}

export async function setSymbol({ symbol }) {
  await evaluateAsync(`
    (function() {
      var chart = ${CHART_API};
      return new Promise(function(resolve) {
        chart.setSymbol('${symbol.replace(/'/g, "\\'")}', {});
        setTimeout(resolve, 500);
      });
    })()
  `);
  const ready = await waitForChartReady(symbol);
  return { success: true, symbol, chart_ready: ready };
}

export async function safeSetSymbol({ symbol }) {
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // ── Step 1: health check ─────────────────────────────────────────
  const health = await evaluate(`
    (function() {
      try {
        var chart = ${CHART_API};
        return { ok: true, symbol: chart.symbol() };
      } catch(e) {
        return { ok: false, error: e.message };
      }
    })()
  `);
  if (!health?.ok) {
    throw new Error('TradingView API not healthy before switch: ' + (health?.error || 'unknown'));
  }
  const previousSymbol = health.symbol;

  // ── Step 2: switch via symbol search box ─────────────────────────
  async function doSwitch() {
    const c = await getClient();

    // Click the symbol name in the header to open the search overlay
    await evaluate(`
      (function() {
        var el = document.querySelector('[data-name="open-instrument-search"]')
          || document.querySelector('[class*="mainSeriesTitle"]')
          || document.querySelector('[class*="symbolTitle"]')
          || document.querySelector('[class*="seriesTitle"]');
        if (el) el.click();
      })()
    `);
    await sleep(600);

    // Try to set the search input value via React's native setter (triggers onChange)
    const sym = symbol.replace(/'/g, "\\'");
    const filled = await evaluate(`
      (function() {
        var input = document.querySelector('input[data-role="search"]')
          || document.querySelector('input[placeholder]');
        if (!input) return false;
        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
        nativeSetter.call(input, '${sym}');
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        input.focus();
        return true;
      })()
    `);

    if (!filled) {
      // Fallback: close any stale overlay and type via keyboard
      await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await c.Input.dispatchKeyEvent({ type: 'keyUp',  key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
      await sleep(200);
      // Select-all + delete any existing text
      await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'a', code: 'KeyA', modifiers: 2, windowsVirtualKeyCode: 65 });
      await c.Input.dispatchKeyEvent({ type: 'keyUp',   key: 'a', code: 'KeyA', modifiers: 2, windowsVirtualKeyCode: 65 });
      await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
      await c.Input.dispatchKeyEvent({ type: 'keyUp',   key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 });
    }

    // Type the symbol char-by-char via keyboard events regardless (ensures search triggers)
    for (const ch of symbol) {
      await c.Input.dispatchKeyEvent({ type: 'char', text: ch });
      await sleep(50);
    }

    // Wait for search dropdown to populate
    await sleep(1200);

    // Press Enter to select the top result
    await c.Input.dispatchKeyEvent({ type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
    await c.Input.dispatchKeyEvent({ type: 'keyUp',   key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });

    // ── Step 3: mandatory 3-second wait ──────────────────────────
    await sleep(3000);
  }

  // ── Step 4: verify by reading chart title ────────────────────────
  async function verify() {
    const state = await evaluate(`
      (function() {
        try {
          var chart = ${CHART_API};
          var sym = chart.symbol();
          // Read the visible symbol/title from the chart header or legend
          var titleEl = document.querySelector('[class*="mainSeriesTitle"]')
            || document.querySelector('[class*="symbolTitle"]')
            || document.querySelector('[class*="seriesTitle"]')
            || document.querySelector('[data-name="legend-source-title"]');
          var title = titleEl ? titleEl.textContent.trim() : sym;
          return { ok: true, symbol: sym, title: title };
        } catch(e) {
          return { ok: false, error: e.message };
        }
      })()
    `);
    if (!state?.ok) return { verified: false, reason: 'API error: ' + state?.error };

    const expectedBase = (symbol.includes(':') ? symbol.split(':')[1] : symbol).toUpperCase();
    const gotSymbol    = (state.symbol || '').toUpperCase();
    const gotTitle     = (state.title  || '').toUpperCase();

    if (gotSymbol.includes(expectedBase) || gotTitle.includes(expectedBase)) {
      return { verified: true, current_symbol: state.symbol, chart_title: state.title };
    }
    return { verified: false, reason: `Expected ${expectedBase}, chart shows ${state.symbol}`, current: state.symbol };
  }

  // First attempt
  await doSwitch();
  let check = await verify();
  if (check.verified) {
    return { success: true, symbol, verified_symbol: check.current_symbol, chart_title: check.chart_title, previous_symbol: previousSymbol, attempts: 1 };
  }

  // ── Step 5: retry once ───────────────────────────────────────────
  await sleep(1000);
  await doSwitch();
  check = await verify();
  if (check.verified) {
    return { success: true, symbol, verified_symbol: check.current_symbol, chart_title: check.chart_title, previous_symbol: previousSymbol, attempts: 2 };
  }

  return { success: false, symbol, error: `Switch failed after 2 attempts: ${check.reason}`, previous_symbol: previousSymbol, current_symbol: check.current };
}

// Pivot-based S&R calculation from an array of {high, low, close} bars
function calcSRFromBars(bars, currentPrice) {
  const WIN = 4; // bars each side for pivot detection
  const pivotHighs = [];
  const pivotLows  = [];

  for (let i = WIN; i < bars.length - WIN; i++) {
    let isHigh = true, isLow = true;
    for (let j = i - WIN; j <= i + WIN; j++) {
      if (j === i) continue;
      if (bars[j].high >= bars[i].high) isHigh = false;
      if (bars[j].low  <= bars[i].low)  isLow  = false;
    }
    if (isHigh) pivotHighs.push(bars[i].high);
    if (isLow)  pivotLows.push(bars[i].low);
  }

  // Cluster levels that are within 0.6% of each other (keep the mean)
  function cluster(levels) {
    const sorted = [...levels].sort((a, b) => a - b);
    const out = [];
    for (const lvl of sorted) {
      const last = out[out.length - 1];
      if (last && Math.abs(lvl - last) / last < 0.006) {
        out[out.length - 1] = (last + lvl) / 2; // merge
      } else {
        out.push(lvl);
      }
    }
    return out;
  }

  const resistance = cluster(pivotHighs)
    .filter(l => l > currentPrice * 1.002)
    .sort((a, b) => a - b)   // nearest first
    .slice(0, 3)
    .map(p => +p.toFixed(2));

  const support = cluster(pivotLows)
    .filter(l => l < currentPrice * 0.998)
    .sort((a, b) => b - a)   // nearest first
    .slice(0, 3)
    .map(p => +p.toFixed(2));

  return { support, resistance };
}

export async function switchWithFreshSR({ symbol }) {
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // ── 1. Switch symbol (includes health check + verify + retry) ────
  const switchResult = await safeSetSymbol({ symbol });
  if (!switchResult.success) {
    return { success: false, symbol, phase: 'switch', error: switchResult.error };
  }

  // ── 2. Clear all drawings immediately ────────────────────────────
  await evaluate(`${CHART_API}.removeAllShapes()`);
  await sleep(300);
  // Confirm cleared
  const remaining = await evaluate(`${CHART_API}.getAllShapes().length`);
  if (remaining > 0) {
    await evaluate(`${CHART_API}.removeAllShapes()`);
    await sleep(300);
  }

  // ── 3. Wait 2 s for chart data to fully settle ───────────────────
  await sleep(2000);

  // ── 4. Read OHLCV and calculate S&R ─────────────────────────────
  let ohlcvResult;
  try {
    ohlcvResult = await getOhlcv({ count: 100 });
  } catch (err) {
    return { success: false, symbol, phase: 'ohlcv', error: 'Could not read bar data after switch: ' + err.message };
  }

  const bars        = ohlcvResult.bars;
  const currentPrice = bars[bars.length - 1].close;
  const { support, resistance } = calcSRFromBars(bars, currentPrice);

  if (support.length === 0 && resistance.length === 0) {
    return { success: true, symbol, phase: 'draw', warning: 'No pivot-based S&R found in last 100 bars', current_price: currentPrice, bars_analysed: bars.length, switch: switchResult };
  }

  // ── 5. Draw S&R (clear again + 1 s gap between lines + verify) ──
  const drawResult = await safeDrawSRLevels({ support, resistance });

  return {
    success: true,
    symbol,
    verified_symbol:  switchResult.verified_symbol,
    previous_symbol:  switchResult.previous_symbol,
    switch_attempts:  switchResult.attempts,
    current_price:    currentPrice,
    bars_analysed:    bars.length,
    support,
    resistance,
    lines_drawn:      drawResult.drawn,
    lines_failed:     drawResult.failed,
    levels:           drawResult.levels,
  };
}

export async function setTimeframe({ timeframe }) {
  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      chart.setResolution('${timeframe.replace(/'/g, "\\'")}', {});
    })()
  `);
  const ready = await waitForChartReady(null, timeframe);
  return { success: true, timeframe, chart_ready: ready };
}

export async function setType({ chart_type }) {
  const typeMap = {
    'Bars': 0, 'Candles': 1, 'Line': 2, 'Area': 3,
    'Renko': 4, 'Kagi': 5, 'PointAndFigure': 6, 'LineBreak': 7,
    'HeikinAshi': 8, 'HollowCandles': 9,
  };
  const typeNum = typeMap[chart_type] ?? Number(chart_type);
  if (isNaN(typeNum)) {
    throw new Error(`Unknown chart type: ${chart_type}. Use a name (Candles, Line, etc.) or number (0-9).`);
  }
  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      chart.setChartType(${typeNum});
    })()
  `);
  return { success: true, chart_type, type_num: typeNum };
}

export async function manageIndicator({ action, indicator, entity_id, inputs: inputsRaw }) {
  const inputs = inputsRaw ? (typeof inputsRaw === 'string' ? JSON.parse(inputsRaw) : inputsRaw) : undefined;

  if (action === 'add') {
    const inputArr = inputs ? Object.entries(inputs).map(([k, v]) => ({ id: k, value: v })) : [];
    const before = await evaluate(`${CHART_API}.getAllStudies().map(function(s) { return s.id; })`);
    await evaluate(`
      (function() {
        var chart = ${CHART_API};
        chart.createStudy('${indicator.replace(/'/g, "\\'")}', false, false, ${JSON.stringify(inputArr)});
      })()
    `);
    await new Promise(r => setTimeout(r, 1500));
    const after = await evaluate(`${CHART_API}.getAllStudies().map(function(s) { return s.id; })`);
    const newIds = (after || []).filter(id => !(before || []).includes(id));
    return { success: newIds.length > 0, action: 'add', indicator, entity_id: newIds[0] || null, new_study_count: newIds.length };
  } else if (action === 'remove') {
    if (!entity_id) throw new Error('entity_id required for remove action. Use chart_get_state to find study IDs.');
    await evaluate(`
      (function() {
        var chart = ${CHART_API};
        chart.removeEntity('${entity_id.replace(/'/g, "\\'")}');
      })()
    `);
    return { success: true, action: 'remove', entity_id };
  } else {
    throw new Error('action must be "add" or "remove"');
  }
}

export async function getVisibleRange() {
  const result = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      return { visible_range: chart.getVisibleRange(), bars_range: chart.getVisibleBarsRange() };
    })()
  `);
  return { success: true, visible_range: result.visible_range, bars_range: result.bars_range };
}

export async function setVisibleRange({ from, to }) {
  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var m = chart._chartWidget.model();
      var ts = m.timeScale();
      var bars = m.mainSeries().bars();
      var startIdx = bars.firstIndex();
      var endIdx = bars.lastIndex();
      var fromIdx = startIdx, toIdx = endIdx;
      for (var i = startIdx; i <= endIdx; i++) {
        var v = bars.valueAt(i);
        if (v && v[0] >= ${from} && fromIdx === startIdx) fromIdx = i;
        if (v && v[0] <= ${to}) toIdx = i;
      }
      ts.zoomToBarsRange(fromIdx, toIdx);
    })()
  `);
  await new Promise(r => setTimeout(r, 500));
  const actual = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      try { var r = chart.getVisibleRange(); return { from: r.from || 0, to: r.to || 0 }; }
      catch(e) { return { from: 0, to: 0, error: e.message }; }
    })()
  `);
  return { success: true, requested: { from, to }, actual: actual || { from: 0, to: 0 } };
}

export async function scrollToDate({ date }) {
  let timestamp;
  if (/^\d+$/.test(date)) timestamp = Number(date);
  else timestamp = Math.floor(new Date(date).getTime() / 1000);
  if (isNaN(timestamp)) throw new Error(`Could not parse date: ${date}. Use ISO format (2024-01-15) or unix timestamp.`);

  const resolution = await evaluate(`${CHART_API}.resolution()`);
  let secsPerBar = 60;
  const res = String(resolution);
  if (res === 'D' || res === '1D') secsPerBar = 86400;
  else if (res === 'W' || res === '1W') secsPerBar = 604800;
  else if (res === 'M' || res === '1M') secsPerBar = 2592000;
  else { const mins = parseInt(res, 10); if (!isNaN(mins)) secsPerBar = mins * 60; }

  const halfWindow = 25 * secsPerBar;
  const from = timestamp - halfWindow;
  const to = timestamp + halfWindow;

  await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var m = chart._chartWidget.model();
      var ts = m.timeScale();
      var bars = m.mainSeries().bars();
      var startIdx = bars.firstIndex();
      var endIdx = bars.lastIndex();
      var fromIdx = startIdx, toIdx = endIdx;
      for (var i = startIdx; i <= endIdx; i++) {
        var v = bars.valueAt(i);
        if (v && v[0] >= ${from} && fromIdx === startIdx) fromIdx = i;
        if (v && v[0] <= ${to}) toIdx = i;
      }
      ts.zoomToBarsRange(fromIdx, toIdx);
    })()
  `);
  await new Promise(r => setTimeout(r, 500));
  return { success: true, date, centered_on: timestamp, resolution, window: { from, to } };
}

export async function symbolInfo() {
  const result = await evaluate(`
    (function() {
      var chart = ${CHART_API};
      var info = chart.symbolExt();
      return {
        symbol: info.symbol, full_name: info.full_name, exchange: info.exchange,
        description: info.description, type: info.type, pro_name: info.pro_name,
        typespecs: info.typespecs, resolution: chart.resolution(), chart_type: chart.chartType()
      };
    })()
  `);
  return { success: true, ...result };
}

export async function symbolSearch({ query, type }) {
  // Use TradingView's public symbol search REST API (works without auth)
  const params = new URLSearchParams({
    text: query,
    hl: '1',
    exchange: '',
    lang: 'en',
    search_type: type || '',
    domain: 'production',
  });

  const resp = await fetch(`https://symbol-search.tradingview.com/symbol_search/v3/?${params}`, {
    headers: { 'Origin': 'https://www.tradingview.com', 'Referer': 'https://www.tradingview.com/' },
  });
  if (!resp.ok) throw new Error(`Symbol search API returned ${resp.status}`);
  const data = await resp.json();

  const strip = s => (s || '').replace(/<\/?em>/g, '');
  const results = (data.symbols || data || []).slice(0, 15).map(r => ({
    symbol: strip(r.symbol),
    description: strip(r.description),
    exchange: r.exchange || r.prefix || '',
    type: r.type || '',
    full_name: r.exchange ? `${r.exchange}:${strip(r.symbol)}` : strip(r.symbol),
  }));

  return { success: true, query, source: 'rest_api', results, count: results.length };
}
