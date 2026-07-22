#!/bin/bash
# fundamental_check.sh v2 — REFINED + Banking Framework
# Auto-detects sector (bank vs regular), falls back to standalone if consolidated < 5 years
# Usage: ./fundamental_check.sh SYMBOL   (e.g. RELIANCE, TCS, HDFCBANK, NESTLEIND)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify.sh"
FA_FILE="$SCRIPT_DIR/fundamental_analysis.json"
BANK_METRICS_FILE="$SCRIPT_DIR/bank_metrics.json"

SYMBOL="${1:-}"
if [ -z "$SYMBOL" ]; then
  echo "Usage: ./fundamental_check.sh SYMBOL   (e.g. RELIANCE, TCS, HDFCBANK)"
  exit 1
fi

export SYMBOL NOTIFY FA_FILE BANK_METRICS_FILE

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Fundamental Analysis — Screener.in            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Symbol   : $SYMBOL"
echo "  Fetching data…"
echo ""

node --input-type=module <<'JSEOF'
import { execSync } from 'child_process';
import { readFileSync } from 'fs';

const SYMBOL  = process.env.SYMBOL.toUpperCase();
const NOTIFY  = process.env.NOTIFY;
const FA_FILE = process.env.FA_FILE;
const BANK_METRICS_FILE = process.env.BANK_METRICS_FILE;

// ── Helpers ───────────────────────────────────────────────────
const clean  = s => s.replace(/<[^>]+>/g,'').replace(/&nbsp;/g,' ').replace(/&#x27;/g,"'").replace(/\s+/g,' ').trim();
const toNum  = s => {
  const n = parseFloat((s||'').replace(/,/g,'').replace('%','').trim());
  return isNaN(n) ? null : n;
};

function fetchPage(url) {
  try {
    return execSync(
      `curl -s -L "${url}" -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" -H "Accept: text/html" --max-time 30`,
      { timeout: 35000 }
    ).toString();
  } catch { return ''; }
}

// ── Free bank-metrics fetcher ─────────────────────────────────
// Screener.in locks NPA/CASA behind login, and Moneycontrol/Tickertape render
// them via client-side JS with no accessible free API (confirmed by direct
// investigation — see bank_metrics.json header comment). This function tries:
//   1. Hardcoded lookup table (bank_metrics.json) — real reported figures,
//      sourced from quarterly-result press coverage, refreshed quarterly by hand
//   2. Trendlyne "about" chip (single current values, JSON blob in HTML)
//   3. P&L/BS estimation from Screener data already fetched
//   4. Manual-verify fallback with direct NSE link
function loadBankMetricsTable(sym) {
  try {
    const table = JSON.parse(readFileSync(BANK_METRICS_FILE, 'utf8'));
    const entry = table.banks[sym];
    if (!entry) return null;
    return {
      gnpa: entry.gnpa,
      nnpa: entry.nnpa,
      casa: entry.casa,
      car: entry.car,
      source: `Hardcoded (${entry.asOf || 'as-of unknown'}) — ${entry.source || 'no source recorded'}`,
      note: entry.note || null,
    };
  } catch {
    return null;
  }
}

function fetchBankMetrics(sym, plRows, bsRows) {
  // Source 1: Trendlyne — annual-results page embeds an "about" chip with current NPA/CASA
  const tlHtml = fetchPage(`https://trendlyne.com/equity/${sym}/annual-results/`);
  let gnpa = null, nnpa = null, casa = null, metricSource = null;

  if (tlHtml && tlHtml.length > 1000) {
    // Unescape HTML entities in the JSON attribute
    const unescape = s => s.replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&amp;/g,'&').replace(/&#x27;/g,"'");
    const chipMatch = tlHtml.match(/data-chips-data\s*=\s*"([\s\S]*?)"(?=\s)/);
    if (chipMatch) {
      try {
        const chips = JSON.parse(unescape(chipMatch[1]));
        const about = chips.find(c => c.key === 'about');
        const txt   = about ? about.insight || '' : '';

        // Gross NPA: "**Gross NPA**: 1.33%" or "Gross NPA**: 1.33%"
        const gnpaM = txt.match(/Gross\s+NPA\*?\*?[:\s]+(\d+\.?\d*)\s*%/i);
        if (gnpaM) gnpa = parseFloat(gnpaM[1]);

        // Net NPA: "**Net NPA**: 0.42%"
        const nnpaM = txt.match(/Net\s+NPA\*?\*?[:\s]+(\d+\.?\d*)\s*%/i);
        if (nnpaM) nnpa = parseFloat(nnpaM[1]);

        // CASA: "CASA ratio (38.2% in FY2025)" or "CASA ratio**: 42.1%"
        const casaM = txt.match(/CASA\s+(?:ratio)?\*?\*?\s*[:\(]?\s*(\d+\.?\d*)\s*%/i);
        if (casaM) casa = parseFloat(casaM[1]);

        if (gnpa !== null || nnpa !== null || casa !== null) {
          metricSource = 'Trendlyne (latest annual report summary)';
        }
      } catch { /* JSON parse failed */ }
    }
  }

  // Source 2: Estimate from Screener P&L/BS data already in memory
  // Gross NPA% ≈ (Net NPA provisions) / (Total Advances) × 100
  // This is a rough proxy, not the actual reported NPA figure
  if (gnpa === null) {
    const provisionsRow = Object.entries(plRows).find(([k]) => /provision/i.test(k));
    const advancesRow   = Object.entries(bsRows).find(([k]) => /advance|loan/i.test(k));
    if (provisionsRow && advancesRow) {
      const latestProv = provisionsRow[1].filter(v => v !== null).slice(-1)[0];
      const latestAdv  = advancesRow[1].filter(v => v !== null).slice(-1)[0];
      if (latestProv && latestAdv && latestAdv > 0) {
        gnpa = parseFloat(((latestProv / latestAdv) * 100).toFixed(2));
        metricSource = (metricSource || '') +
          ' + Estimated NPA from Screener (Provisions/Advances — approximate, not the reported figure)';
      }
    }
  }

  return { gnpa, nnpa, casa, source: metricSource };
}

function countPLYears(html) {
  const plS = html.indexOf('id="profit-loss"');
  const bsS = html.indexOf('id="balance-sheet"');
  if (plS < 0 || bsS < 0) return 0;
  const plHtml = html.slice(plS, bsS);
  const thRe = /<th[^>]*>([\s\S]*?)<\/th>/g;
  let m, count = 0;
  while ((m = thRe.exec(plHtml)) !== null) {
    if (/20\d\d/.test(clean(m[1]))) count++;
  }
  return count;
}

function extractSection(html, startId, endId) {
  const s = html.indexOf(`id="${startId}"`);
  const e = endId ? html.indexOf(`id="${endId}"`, s + 1) : html.length;
  return s >= 0 ? html.slice(s, e > s ? e : html.length) : '';
}

function getYears(sectionHtml) {
  const thRe = /<th[^>]*>([\s\S]*?)<\/th>/g;
  const years = [];
  let m;
  while ((m = thRe.exec(sectionHtml)) !== null) {
    const t = clean(m[1]);
    if (/20\d\d/.test(t)) years.push(t);
  }
  return years;
}

function parseRows(sectionHtml) {
  const rows = {};
  const rowRe = /<tr[^>]*>([\s\S]*?)<\/tr>/g;
  let m;
  while ((m = rowRe.exec(sectionHtml)) !== null) {
    const cells = [];
    const cellRe = /<td[^>]*>([\s\S]*?)<\/td>/g;
    let c;
    while ((c = cellRe.exec(m[0])) !== null) cells.push(clean(c[1]));
    if (cells.length > 1 && cells[0]) {
      const label = cells[0].replace(/\+$/, '').replace(/・.*/, '').trim();
      if (!label || /^x[.,x]/.test(label)) continue;       // skip locked rows
      const vals = cells.slice(1).map(toNum);
      if (!rows[label]) rows[label] = vals;
    }
  }
  return rows;
}

function get(rows, ...keys) {
  for (const k of keys) {
    for (const label of Object.keys(rows)) {
      if (label.toLowerCase().includes(k.toLowerCase())) return rows[label];
    }
  }
  return [];
}

// last N non-null values
const last = (arr, n = 5) => (arr||[]).filter(v => v !== null).slice(-n);

// ── 1. Fetch page — consolidated first, standalone fallback ───
const consolidatedURL = `https://www.screener.in/company/${SYMBOL}/consolidated/`;
const standaloneURL   = `https://www.screener.in/company/${SYMBOL}/`;

let html        = fetchPage(consolidatedURL);
let dataSource  = 'Consolidated';

if (!html || html.length < 5000 || html.includes('Page not found')) {
  console.error(`❌  Symbol "${SYMBOL}" not found on Screener.in. Check spelling.`);
  process.exit(1);
}

const consolidatedYears = countPLYears(html);

if (consolidatedYears < 5) {
  console.log(`  ⚠️   Consolidated only has ${consolidatedYears} year(s) — fetching standalone for full history…`);
  const standaloneHtml  = fetchPage(standaloneURL);
  const standaloneYears = countPLYears(standaloneHtml);
  if (standaloneYears > consolidatedYears) {
    html       = standaloneHtml;
    dataSource = `Standalone (consolidated had only ${consolidatedYears} year(s) — fiscal year change)`;
    console.log(`  ✅  Using standalone: ${standaloneYears} years available`);
  }
}

// ── 2. Extract sections ───────────────────────────────────────
const plHtml  = extractSection(html, 'profit-loss',  'balance-sheet');
const bsHtml  = extractSection(html, 'balance-sheet', 'cash-flow');
const cfHtml  = extractSection(html, 'cash-flow',    'ratios');
const ratHtml = extractSection(html, 'ratios',       'shareholding');

const plRows  = parseRows(plHtml);
const bsRows  = parseRows(bsHtml);
const cfRows  = parseRows(cfHtml);
const ratRows = parseRows(ratHtml);
const plYears = getYears(plHtml);
const Y       = 5;
const yearLabels = plYears.slice(-Y);

// ── 3. Company name + sector detection ───────────────────────
const nameMatch   = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
const companyName = nameMatch ? clean(nameMatch[1]).split('|')[0].trim() : SYMBOL;

const sectorMatch = html.match(/Sector">([^<]+)/);
const sector      = sectorMatch ? sectorMatch[1].trim() : 'Unknown';

// Bank/NBFC detection: by sector OR by P&L structure (banks have "Financing Profit" not "Operating Profit")
const hasBankPL    = !!plRows['Financing Profit'] || !!plRows['Financing Margin %'];
const hasBankSect  = /Financial Services|Banks|NBFC|Banking/i.test(sector);
const hasNPALabel  = /Gross NPA|GNPA|Net NPA|NNPA/i.test(html);
const isBank       = hasBankPL || hasBankSect || hasNPALabel;

// ── 4. Run scoring framework ──────────────────────────────────
const results = [];

function addResult(id, name, verdict, reason, values = []) {
  results.push({ id, name, verdict, reason, values });
}

function scoreThreshold(id, name, vals, yearLbls, opts) {
  const { threshold, direction, warnAt = 1, rejectAt = 2, unit = '', fmt = v => v + unit } = opts;
  const valid = vals.filter(v => v !== null);
  if (valid.length === 0) {
    addResult(id, name, 'WARN', 'No data available on Screener.in free tier — manual verification required', []);
    return;
  }
  const failing = direction === 'above'
    ? valid.filter(v => v < threshold)
    : valid.filter(v => v > threshold);

  const display = `Values: ${valid.map(fmt).join(', ')}`;
  if (failing.length === 0) {
    addResult(id, name, 'PASS', `All ${direction} ${threshold}${unit}. ${display}`, valid);
  } else if (failing.length < warnAt + 1) {
    addResult(id, name, 'WARN', `${failing.length} year(s) ${direction === 'above' ? 'below' : 'above'} ${threshold}${unit}. ${display}`, valid);
  } else {
    addResult(id, name, 'REJECT', `${failing.length} year(s) failing threshold (${threshold}${unit}). ${display}`, valid);
  }
}

// ════════════════════════════════════════════════════════
// BANKING FRAMEWORK
// ════════════════════════════════════════════════════════
if (isBank) {

  // NIM (estimated) = (Revenue − Interest) / Avg Total Assets × 100
  const revenue     = get(plRows, 'Revenue', 'Total Income', 'Interest Earned');
  const intExp      = get(plRows, 'Interest');
  const totalAssets = get(bsRows, 'Total Assets', 'Total Liabilities');
  const roeRow      = get(ratRows, 'ROE');
  const epsRow      = get(plRows, 'EPS');
  const divPayRow   = get(plRows, 'Dividend Payout');
  const netProfRow  = get(plRows, 'Net Profit');
  const finMargin   = get(plRows, 'Financing Margin');

  // Calculate estimated NIM
  const nimCalc = [];
  const revL = last(revenue, Y + 1);
  const intL = last(intExp,  Y + 1);
  const assL = last(totalAssets, Y + 1);
  const pairLen = Math.min(revL.length, intL.length, assL.length);
  for (let i = 1; i < pairLen; i++) {
    const nii = (revL[i] ?? 0) - (intL[i] ?? 0);
    const avgAssets = ((assL[i] ?? 0) + (assL[i-1] ?? 0)) / 2;
    if (avgAssets > 0) nimCalc.push(parseFloat((nii / avgAssets * 100).toFixed(2)));
  }
  const nimL5 = nimCalc.slice(-Y);

  // ROE
  const roeL5 = last(roeRow, Y);

  // EPS
  const epsL5 = last(epsRow, Y);

  // Dividend payout
  const divL5 = last(divPayRow, Y);

  // Net profit trend
  const netPL5 = last(netProfRow, Y);

  // Financing Margin (Screener's bank OPM proxy)
  const fmL5   = last(finMargin, Y);

  // -- Score: NIM (estimated) --
  if (nimL5.length > 0) {
    scoreThreshold('NIM', 'NIM % (estimated)', nimL5, yearLabels,
      { threshold: 3, direction: 'above', warnAt: 1, rejectAt: 2, unit: '%', fmt: v => v.toFixed(2) + '%' });
    results[results.length-1].reason = '(Estimated: NII / Avg Total Assets) ' + results[results.length-1].reason;
  } else {
    addResult('NIM', 'NIM % (estimated)', 'WARN', 'Could not calculate — Revenue or Total Assets missing', []);
  }

  // -- Score: Gross NPA, Net NPA, CASA --
  // Screener.in locks these; try the hardcoded lookup table, then Trendlyne,
  // then manual-verify fallback
  const gnpaRow = get(ratRows, 'Gross NPA', 'GNPA');
  const gnpaL5  = last(gnpaRow, Y);
  const nnpaRow = get(ratRows, 'Net NPA', 'NNPA');
  const nnpaL5  = last(nnpaRow, Y);
  const casaRow = get(ratRows, 'CASA');
  const casaL5  = last(casaRow, Y);

  const needsAlt = gnpaL5.length === 0 || nnpaL5.length === 0 || casaL5.length === 0;

  // Fetch from free alternative sources if Screener doesn't have the data
  let bankMetrics = { gnpa: null, nnpa: null, casa: null, car: null, source: null };
  let gnpaSource = null, nnpaSource = null, casaSource = null, carSource = null;
  if (needsAlt) {
    const hardcoded = loadBankMetricsTable(SYMBOL);
    if (hardcoded) {
      bankMetrics = hardcoded;
      gnpaSource = nnpaSource = casaSource = carSource = hardcoded.source;
      process.stdout.write(`  ✅  Bank metrics source: ${hardcoded.source}\n`);
      if (hardcoded.note) process.stdout.write(`  ℹ️   ${hardcoded.note}\n`);
    }
    // Fill in anything the lookup table didn't have from Trendlyne
    if (bankMetrics.gnpa === null || bankMetrics.nnpa === null || bankMetrics.casa === null) {
      process.stdout.write('  ⟳  Fetching remaining NPA/CASA fields from Trendlyne…\n');
      const tl = fetchBankMetrics(SYMBOL, plRows, bsRows);
      if (bankMetrics.gnpa === null && tl.gnpa !== null) { bankMetrics.gnpa = tl.gnpa; gnpaSource = tl.source; }
      if (bankMetrics.nnpa === null && tl.nnpa !== null) { bankMetrics.nnpa = tl.nnpa; nnpaSource = tl.source; }
      if (bankMetrics.casa === null && tl.casa !== null) { bankMetrics.casa = tl.casa; casaSource = tl.source; }
      if (tl.source) process.stdout.write(`  ✅  Trendlyne source: ${tl.source}\n`);
    }
    if (bankMetrics.gnpa === null && bankMetrics.nnpa === null && bankMetrics.casa === null) {
      process.stdout.write('  ⚠️   No free source found — using manual-verify fallback\n');
    }
  }

  // Gross NPA
  if (gnpaL5.length > 0) {
    scoreThreshold('NPA', 'Gross NPA %', gnpaL5, yearLabels,
      { threshold: 3, direction: 'below', warnAt: 1, rejectAt: 1, unit: '%', fmt: v => v.toFixed(2) + '%' });
  } else if (bankMetrics.gnpa !== null) {
    const v = bankMetrics.gnpa;
    const verdict = v < 3 ? 'PASS' : v < 5 ? 'WARN' : 'REJECT';
    const isEst   = gnpaSource && gnpaSource.includes('Estimated');
    addResult('NPA', isEst ? 'Gross NPA % (estimated)' : 'Gross NPA % (latest)',
      verdict,
      `${v.toFixed(2)}% — threshold <3% (PASS), 3–5% (WARN), >5% (REJECT). Source: ${gnpaSource}`,
      [v]);
  } else {
    addResult('NPA', 'Gross NPA % (manual verify)', 'WARN',
      `Not available from any free source. Check: https://www.nseindia.com/companies-listing/corporate-filings-financial-results?symbol=${SYMBOL}`, []);
  }

  // Net NPA
  if (nnpaL5.length > 0) {
    scoreThreshold('NNPA', 'Net NPA %', nnpaL5, yearLabels,
      { threshold: 1, direction: 'below', warnAt: 1, rejectAt: 1, unit: '%', fmt: v => v.toFixed(2) + '%' });
  } else if (bankMetrics.nnpa !== null) {
    const v = bankMetrics.nnpa;
    const verdict = v < 1 ? 'PASS' : v < 2 ? 'WARN' : 'REJECT';
    addResult('NNPA', 'Net NPA % (latest)', verdict,
      `${v.toFixed(2)}% — threshold <1% (PASS), 1–2% (WARN), >2% (REJECT). Source: ${nnpaSource}`, [v]);
  } else {
    addResult('NNPA', 'Net NPA % (manual verify)', 'WARN',
      `Not available from any free source. Check: https://www.nseindia.com/companies-listing/corporate-filings-financial-results?symbol=${SYMBOL}`, []);
  }

  // CASA
  if (casaL5.length > 0) {
    const avg = casaL5.reduce((a,b) => a+b, 0) / casaL5.length;
    addResult('CASA', 'CASA Ratio', avg >= 40 ? 'PASS' : avg >= 35 ? 'WARN' : 'REJECT',
      `Average CASA: ${avg.toFixed(1)}% (target >40%). Values: ${casaL5.map(v=>v+'%').join(', ')}`, casaL5);
  } else if (bankMetrics.casa !== null) {
    const v = bankMetrics.casa;
    const verdict = v >= 40 ? 'PASS' : v >= 35 ? 'WARN' : 'REJECT';
    addResult('CASA', 'CASA Ratio (latest)', verdict,
      `${v.toFixed(1)}% — target >40% (cheaper cost of funds). Source: ${casaSource}`, [v]);
  } else {
    addResult('CASA', 'CASA Ratio (manual verify)', 'WARN',
      `Not available from any free source. Strong CASA (>40%) = cheaper cost of funds. Check: https://www.nseindia.com/companies-listing/corporate-filings-financial-results?symbol=${SYMBOL}`, []);
  }

  // -- Score: ROE --
  if (roeL5.length > 0) {
    scoreThreshold('ROE', 'ROE % > 12%', roeL5, yearLabels,
      { threshold: 12, direction: 'above', warnAt: 1, rejectAt: 2, unit: '%', fmt: v => v + '%' });
  } else {
    addResult('ROE', 'ROE %', 'WARN', 'No ROE data found', []);
  }

  // -- Score: CAR (Capital Adequacy Ratio) --
  const carRow = get(ratRows, 'CAR', 'Capital Adequacy', 'Total Capital Adequacy');
  const carL5  = last(carRow, Y);
  if (carL5.length > 0) {
    scoreThreshold('CAR', 'CAR % > 11%', carL5, yearLabels,
      { threshold: 11, direction: 'above', warnAt: 1, rejectAt: 1, unit: '%', fmt: v => v + '%' });
  } else if (bankMetrics.car !== null) {
    const v = bankMetrics.car;
    addResult('CAR', 'CAR % (latest)', v >= 11.5 ? 'PASS' : 'REJECT',
      `${v.toFixed(2)}% — RBI minimum 11.5%. Source: ${carSource}`, [v]);
  } else {
    addResult('CAR', 'Capital Adequacy Ratio', 'WARN',
      'Not available on Screener.in. RBI minimum = 11.5%. Major private banks typically 15–19%. Verify from annual report.', []);
  }

  // -- Score: EPS (no zero/negative) --
  if (epsL5.length > 0) {
    const bad = epsL5.filter(v => v <= 0);
    if (bad.length > 0) {
      addResult('EPS', 'EPS (no zero/negative)', 'REJECT',
        `EPS negative in ${bad.length} year(s). Values: ₹${epsL5.join(', ₹')}`, epsL5);
    } else {
      addResult('EPS', 'EPS (positive trend)', 'PASS',
        `All positive. Values: ₹${epsL5.join(', ₹')}`, epsL5);
    }
  }

// ════════════════════════════════════════════════════════
// REFINED FRAMEWORK (regular companies)
// ════════════════════════════════════════════════════════
} else {

  const sales       = get(plRows, 'Sales');
  const netProfit   = get(plRows, 'Net Profit');
  const interest    = get(plRows, 'Interest');
  const pbt         = get(plRows, 'Profit before tax');
  const epsRow      = get(plRows, 'EPS');
  const divPayRow   = get(plRows, 'Dividend Payout');
  const fcfRow      = get(cfRows,  'Free Cash Flow');
  const roceRow     = get(ratRows, 'ROCE');

  const roceL5      = last(roceRow,   Y);
  const epsL5       = last(epsRow,    Y);
  const fcfL5       = last(fcfRow,    Y);
  const divL5       = last(divPayRow, Y);
  const salesL5     = last(sales,     Y);
  const npL5        = last(netProfit, Y);
  const intL5       = last(interest,  Y);
  const pbtL5       = last(pbt,       Y);

  // Net Margin CAGR
  const netMarginL5 = salesL5.map((s, i) => (npL5[i] != null && s) ? +(npL5[i] / s * 100).toFixed(2) : null).filter(Boolean);

  // Interest Coverage = (PBT + Interest) / Interest
  const icL5 = intL5.map((i, idx) =>
    (i && pbtL5[idx] != null) ? +((pbtL5[idx] + i) / i).toFixed(2) : null
  ).filter(Boolean);

  // ── R: ROCE > 15% ──
  if (roceL5.length > 0) {
    const below = roceL5.filter(v => v < 15);
    const disp  = `Values: ${roceL5.map(v=>v+'%').join(', ')}`;
    if (below.length === 0)      addResult('R', 'ROCE > 15%', 'PASS',   `All above 15%. ${disp}`, roceL5);
    else if (below.length === 1) addResult('R', 'ROCE > 15%', 'WARN',   `1 year below 15% (${below[0]}%). ${disp}`, roceL5);
    else                         addResult('R', 'ROCE > 15%', 'REJECT', `${below.length} years below 15%. ${disp}`, roceL5);
  } else {
    addResult('R', 'ROCE > 15%', 'WARN', 'No ROCE data available on Screener.in for this company', []);
  }

  // ── E1: EPS positive ──
  if (epsL5.length > 0) {
    const bad  = epsL5.filter(v => v <= 0);
    const disp = `Values: ₹${epsL5.join(', ₹')}`;
    if (bad.length > 0) addResult('E1', 'EPS (no zero/negative)', 'REJECT', `EPS ≤0 in ${bad.length} year(s). ${disp}`, epsL5);
    else {
      const trend = epsL5.at(-1) > epsL5[0];
      addResult('E1', 'EPS (no zero/negative)', 'PASS',
        `All positive${trend ? ' with upward trend' : ' (flat/minor dip — monitor)'}. ${disp}`, epsL5);
    }
  } else {
    addResult('E1', 'EPS (no zero/negative)', 'WARN', 'No EPS data found', []);
  }

  // ── F: FCF trend ──
  if (fcfL5.length > 0) {
    const negCount = fcfL5.filter(v => v < 0).length;
    const disp     = `Values: ${fcfL5.map(v => v.toLocaleString('en-IN')).join(', ')} Cr`;
    if (negCount >= 3) addResult('F', 'FCF Trend', 'REJECT', `FCF negative in ${negCount}/5 years (≥3 = reject). ${disp}`, fcfL5);
    else if (negCount > 0) {
      const slope = fcfL5.at(-1) > fcfL5[0];
      addResult('F', 'FCF Trend', 'WARN',
        `${negCount} negative year(s). Trend ${slope ? 'improving ✅' : 'worsening ⚠️'}. ${disp}`, fcfL5);
    } else addResult('F', 'FCF Trend', 'PASS', `All positive. ${disp}`, fcfL5);
  } else {
    addResult('F', 'FCF Trend', 'WARN', 'No FCF data available on Screener.in', []);
  }

  // ── I: Interest Coverage ──
  if (icL5.length > 0) {
    const danger = icL5.filter(v => v < 1.0);
    const weak   = icL5.filter(v => v >= 1.0 && v < 3.0);
    const disp   = `Values: ${icL5.map(v => v.toFixed(1) + '×').join(', ')}`;
    if (danger.length > 0) addResult('I', 'Interest Coverage', 'REJECT', `Coverage <1× in ${danger.length} year(s). ${disp}`, icL5);
    else if (weak.length > 1) addResult('I', 'Interest Coverage', 'WARN', `Coverage <3× in ${weak.length} years. ${disp}`, icL5);
    else addResult('I', 'Interest Coverage', 'PASS', `All above 3×. ${disp}`, icL5);
  } else {
    addResult('I', 'Interest Coverage', 'WARN', 'Insufficient data to calculate', []);
  }

  // ── N: Net Margin CAGR ──
  if (netMarginL5.length >= 2) {
    const neg = netMarginL5.filter(v => v < 0);
    if (neg.length > 0) {
      addResult('N', 'Net Margin CAGR', 'REJECT',
        `Negative net margin in ${neg.length} year(s). Values: ${netMarginL5.map(v=>v.toFixed(1)+'%').join(', ')}`, netMarginL5);
    } else {
      const cagr = (Math.pow(netMarginL5.at(-1) / netMarginL5[0], 1/(netMarginL5.length-1)) - 1) * 100;
      addResult('N', 'Net Margin CAGR', cagr >= 0 ? 'PASS' : 'WARN',
        `5yr CAGR: ${cagr >= 0 ? '+' : ''}${cagr.toFixed(1)}% (${cagr >= 0 ? 'expanding' : 'shrinking'} margins). Values: ${netMarginL5.map(v=>v.toFixed(1)+'%').join(', ')}`,
        netMarginL5);
    }
  } else {
    addResult('N', 'Net Margin CAGR', 'WARN', 'Insufficient data to calculate net margins', []);
  }

  // ── E2: Economic Moat (known list + fallback) ──
  const knownMoats = {
    RELIANCE:   { moat: 'Cost Efficiency (Jamnagar scale) + Brand Loyalty (Jio)', verdict: 'PASS' },
    TCS:        { moat: 'Switching Cost (long-term enterprise IT contracts)',       verdict: 'PASS' },
    INFY:       { moat: 'Switching Cost (enterprise IT services)',                 verdict: 'PASS' },
    WIPRO:      { moat: 'Switching Cost (enterprise IT)',                          verdict: 'PASS' },
    HCLTECH:    { moat: 'Switching Cost (IT services)',                            verdict: 'PASS' },
    TECHM:      { moat: 'Switching Cost (IT services)',                            verdict: 'PASS' },
    NESTLEIND:  { moat: 'Brand Loyalty (Maggi, KitKat, Nescafé — pricing power)', verdict: 'PASS' },
    ASIANPAINT: { moat: 'Brand Loyalty + Distribution Network',                   verdict: 'PASS' },
    TITAN:      { moat: 'Brand Loyalty (Tanishq Jewellery + Watches)',             verdict: 'PASS' },
    MARICO:     { moat: 'Brand Loyalty (Parachute, Saffola)',                      verdict: 'PASS' },
    HINDUNILVR: { moat: 'Brand Loyalty (FMCG portfolio)',                          verdict: 'PASS' },
    DABUR:      { moat: 'Brand Loyalty (Ayurvedic FMCG)',                         verdict: 'PASS' },
    PIDILITIND: { moat: 'Brand Loyalty (Fevicol monopoly — builders specify brand by name)', verdict: 'PASS' },
    BAJFINANCE: { moat: 'Switching Cost + Network Effect (lending ecosystem)',     verdict: 'PASS' },
    BAJAJFINSV: { moat: 'Switching Cost (financial services)',                     verdict: 'PASS' },
    ITC:        { moat: 'Brand Loyalty (cigarettes pricing power) + Distribution', verdict: 'PASS' },
    COAL:       { moat: 'Natural Monopoly (captive coal reserves)',                verdict: 'PASS' },
    ULTRATECH:  { moat: 'Cost Efficiency (logistics scale in cement)',             verdict: 'PASS' },
    GRASIM:     { moat: 'Cost Efficiency (VSF + cement)',                         verdict: 'PASS' },
    LT:         { moat: 'Switching Cost (infrastructure + engineering projects)', verdict: 'PASS' },
    DRREDDY:    { moat: 'Cost Efficiency (generic pharma scale)',                 verdict: 'PASS' },
    SUNPHARMA:  { moat: 'Brand Loyalty (domestic formulations) + Scale',         verdict: 'PASS' },
    CIPLA:      { moat: 'Brand Loyalty (domestic pharma) + Scale',               verdict: 'PASS' },
    DIVISLAB:   { moat: 'Cost Efficiency (API manufacturing)',                    verdict: 'PASS' },
    MARUTI:     { moat: 'Scale + Distribution (largest dealer network in India)', verdict: 'PASS' },
    HEROMOTOCO: { moat: 'Scale + Brand Loyalty (2-wheeler dominance)',            verdict: 'PASS' },
    EICHERMOT:  { moat: 'Brand Loyalty (Royal Enfield lifestyle brand)',          verdict: 'PASS' },
    BRITANNIA:  { moat: 'Brand Loyalty (biscuits + distribution reach)',          verdict: 'PASS' },
    TATACONSUM: { moat: 'Brand Loyalty (Tata Tea, Tata Salt)',                   verdict: 'PASS' },
    ADANIENT:   { moat: 'Natural Monopoly (ports, airports infrastructure)',      verdict: 'PASS' },
    POWERGRID:  { moat: 'Natural Monopoly (transmission infrastructure)',         verdict: 'PASS' },
    NTPC:       { moat: 'Natural Monopoly (power generation)',                    verdict: 'PASS' },
  };
  const moatInfo = knownMoats[SYMBOL] || { moat: 'Unknown — manual review required (check ROCE trend + market share stability)', verdict: 'WARN' };
  addResult('E2', 'Economic Moat', moatInfo.verdict, moatInfo.moat, []);

  // ── D: Dividends ──
  if (divL5.length > 0) {
    const zeroYears = divL5.filter(v => v === 0 || v === null).length;
    const disp      = `Payout%: ${divL5.map(v => v+'%').join(', ')}`;
    if (zeroYears > 0) addResult('D', 'Dividends (no zero year)', 'REJECT', `Zero dividend in ${zeroYears} year(s). ${disp}`, divL5);
    else addResult('D', 'Dividends (no zero year)', 'PASS', `Paid every year. ${disp}`, divL5);
  } else {
    addResult('D', 'Dividends (no zero year)', 'WARN', 'No dividend data found', []);
  }
}

// ── 5. Final verdict ──────────────────────────────────────────
const rejects = results.filter(r => r.verdict === 'REJECT').length;
const warns   = results.filter(r => r.verdict === 'WARN').length;
const passes  = results.filter(r => r.verdict === 'PASS').length;

let verdict, verdictEmoji;
if (rejects > 0)       { verdict = 'AVOID';       verdictEmoji = '🔴'; }
else if (warns === 0)  { verdict = 'STRONG BUY';  verdictEmoji = '🟢'; }
else if (warns === 1)  { verdict = 'BUY';         verdictEmoji = '🟢'; }
else if (warns === 2)  { verdict = 'WATCH';       verdictEmoji = '🟡'; }
else                   { verdict = 'AVOID';        verdictEmoji = '🔴'; }

// For banks: locked data counts as warns — don't AVOID purely on locked data
// but do cap at WATCH if there are many locked warns
if (isBank && rejects === 0 && warns > 2) {
  const lockedWarns = results.filter(r => r.verdict === 'WARN' && r.reason.includes('locked')).length;
  const realWarns   = warns - lockedWarns;
  if (realWarns === 0)      { verdict = 'BUY';   verdictEmoji = '🟢'; }
  else if (realWarns === 1) { verdict = 'BUY';   verdictEmoji = '🟢'; }
  else if (realWarns === 2) { verdict = 'WATCH'; verdictEmoji = '🟡'; }
  // Note appended to verdict
  verdict += ' (verify NPA/CASA manually)';
}

// ── 6. Print report ───────────────────────────────────────────
const W  = 62;
const hr = '═'.repeat(W);
const frameworkLabel = isBank ? 'BANKING FRAMEWORK (NIM + NPA + ROE + CAR)' : 'REFINED Framework';

console.log(`\n╔${hr}╗`);
console.log(`║  ${companyName.slice(0,W-4).padEnd(W-2)}║`);
console.log(`║  ${'NSE/' + SYMBOL + ' · ' + dataSource}  `.padEnd(W+1) + '║');
console.log(`║  ${'Sector: ' + sector + ' · ' + frameworkLabel}  `.padEnd(W+1) + '║');
console.log(`║  ${'Years (last 5): ' + (yearLabels.length ? yearLabels.join(', ') : 'N/A')}  `.padEnd(W+1) + '║');
console.log(`╠${hr}╣`);
console.log(`║  ${'CRITERION'.padEnd(30)} ${'VERDICT'.padEnd(8)} DETAIL`.padEnd(W+1) + '║');
console.log(`╠${hr}╣`);

for (const r of results) {
  const icon    = r.verdict === 'PASS' ? '✅' : r.verdict === 'WARN' ? '⚠️ ' : '❌';
  const label   = `[${r.id}] ${r.name}`.slice(0, 30).padEnd(30);
  const verdict_= r.verdict.slice(0,6).padEnd(7);
  console.log(`║  ${icon} ${label} ${verdict_}║`);
  const chunks = r.reason.match(new RegExp(`.{1,${W-7}}(\\s|$)`, 'g')) || [r.reason];
  chunks.forEach(line => console.log(`║      ${line.trimEnd().padEnd(W-6)}║`));
  console.log(`║  ${''.padEnd(W-2)}║`);
}

console.log(`╠${hr}╣`);
console.log(`║  ${'SCORE: '.padEnd(W-2)}║`);
console.log(`║    ✅ PASS: ${String(passes).padEnd(3)} ⚠️  WARN: ${String(warns).padEnd(3)} ❌ REJECT: ${String(rejects).padEnd(18)}║`);
console.log(`╠${hr}╣`);
console.log(`║  FINAL VERDICT: ${verdictEmoji} ${verdict.padEnd(W-18)}║`);
console.log(`╚${hr}╝\n`);

// ── 7. Send notification ──────────────────────────────────────
const rejectNames = results.filter(r => r.verdict === 'REJECT').map(r => r.id).join(', ') || 'None';
const warnNames   = results.filter(r => r.verdict === 'WARN').map(r => r.id).join(', ')   || 'None';
const title       = `${verdictEmoji} ${SYMBOL} — ${verdict}`;
const msg         = `${isBank ? 'Banking' : 'REFINED'}: ${passes}✅ ${warns}⚠️ ${rejects}❌ | Rejects: ${rejectNames} | Warns: ${warnNames}`;

try {
  execSync(`"${NOTIFY}" "${title}" "${msg}"`, { timeout: 5000 });
  console.log(`  🔔  Notification sent: "${title}"`);
  console.log(`      "${msg}"\n`);
} catch(e) {
  console.log(`  ⚠️   Notification failed: ${e.message}`);
}
JSEOF
