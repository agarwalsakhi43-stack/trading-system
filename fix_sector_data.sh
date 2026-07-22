#!/bin/bash
# fix_sector_data.sh — fills sector: "Unknown" in full_market_watchlist.json using Screener.in
# Runs in batches of 50, saves progress after each batch, fully resumable.
# Usage: ./fix_sector_data.sh          (start or resume automatically)
#        ./fix_sector_data.sh --reset  (clear progress and restart from scratch)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "--reset" ]; then
  rm -f "$SCRIPT_DIR/fix_sector_progress.json"
  echo "Progress reset. Starting from scratch."
fi

export SCRIPT_DIR

node --input-type=module <<'JSEOF'
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';

const WATCHLIST_PATH = process.env.SCRIPT_DIR + '/full_market_watchlist.json';
const PROGRESS_PATH  = process.env.SCRIPT_DIR + '/fix_sector_progress.json';
const BATCH_SIZE     = 50;
const REQUEST_DELAY  = 1500;   // ms between Screener.in requests
const BATCH_PAUSE    = 8000;   // ms pause between batches

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ── Load watchlist ───────────────────────────────────────────────
const wl = JSON.parse(readFileSync(WATCHLIST_PATH, 'utf8'));

// ── Load or init progress ────────────────────────────────────────
let progress = existsSync(PROGRESS_PATH)
  ? JSON.parse(readFileSync(PROGRESS_PATH, 'utf8'))
  : { processed: {} };   // processed[symbol] = sector string found (or 'NOT_FOUND')

const alreadyDone = new Set(Object.keys(progress.processed));

// ── Find remaining work ──────────────────────────────────────────
const todo = wl.stocks.filter(s => s.sector === 'Unknown' && !alreadyDone.has(s.symbol));
const totalUnknown = wl.stocks.filter(s => s.sector === 'Unknown').length;

console.log('');
console.log('╔══════════════════════════════════════════════════════════╗');
console.log('║       SECTOR FILLER — full_market_watchlist.json         ║');
console.log(`║  Unknown: ${String(totalUnknown).padEnd(5)}  Already done: ${String(alreadyDone.size).padEnd(5)}  Remaining: ${String(todo.length).padEnd(5)}  ║`);
console.log('╚══════════════════════════════════════════════════════════╝');
console.log('');

if (todo.length === 0) {
  console.log('  ✅  Nothing to do — all previously unknown sectors are resolved.');
  printFinalStats();
  process.exit(0);
}

const estMins = Math.ceil((todo.length * (REQUEST_DELAY + 200)) / 60000);
console.log(`  Est. time: ~${estMins} minutes for ${todo.length} remaining stocks`);
console.log('  (Progress saved after every 50 stocks — safe to Ctrl+C and resume)\n');

// ── Screener.in fetch + sector extraction ────────────────────────
function fetchSector(symbol) {
  const url = `https://www.screener.in/company/${symbol}/`;
  let html = '';
  try {
    html = execSync(
      `curl -s -L "${url}" ` +
      `-H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" ` +
      `-H "Accept: text/html" --max-time 20`,
      { timeout: 25000, maxBuffer: 10 * 1024 * 1024 }
    ).toString();
  } catch { return null; }

  if (!html || html.length < 500) return null;
  // Matches: data-name="Sector">Consumer Durables</span>
  const m = html.match(/Sector">([^<]+)/);
  return m ? m[1].trim() : null;
}

// ── Apply found sectors back to watchlist ────────────────────────
function applyAndSave() {
  const sectorMap = progress.processed;
  let applied = 0;
  for (const stock of wl.stocks) {
    if (stock.sector === 'Unknown' && sectorMap[stock.symbol] && sectorMap[stock.symbol] !== 'NOT_FOUND') {
      stock.sector = sectorMap[stock.symbol];
      applied++;
    }
  }
  const stillUnknown = wl.stocks.filter(s => s.sector === 'Unknown').length;
  wl.total_included = wl.stocks.length;
  writeFileSync(WATCHLIST_PATH, JSON.stringify(wl, null, 2));
  writeFileSync(PROGRESS_PATH,  JSON.stringify(progress, null, 2));
  return { applied, stillUnknown };
}

function printFinalStats() {
  const filled      = Object.values(progress.processed).filter(v => v !== 'NOT_FOUND').length;
  const notFound    = Object.values(progress.processed).filter(v => v === 'NOT_FOUND').length;
  const stillLeft   = wl.stocks.filter(s => s.sector === 'Unknown').length;
  console.log('\n  ─────────────────────────────────────────────────────────');
  console.log(`  ✅  Sectors filled    : ${filled}`);
  console.log(`  ⚠️   Not on Screener   : ${notFound}`);
  console.log(`  ❓  Still Unknown     : ${stillLeft}`);
  console.log(`  📦  Total stocks      : ${wl.stocks.length}`);
  console.log('  ─────────────────────────────────────────────────────────\n');
}

// ── Main batch loop ──────────────────────────────────────────────
let batchNum  = 0;
let totalFilled = 0;

for (let i = 0; i < todo.length; i += BATCH_SIZE) {
  batchNum++;
  const batch = todo.slice(i, i + BATCH_SIZE);
  const batchEnd = Math.min(i + BATCH_SIZE, todo.length);
  console.log(`  ── Batch ${batchNum} (stocks ${i + 1}–${batchEnd} of ${todo.length}) ──`);

  for (let j = 0; j < batch.length; j++) {
    const stock  = batch[j];
    const overall = i + j + 1;
    process.stdout.write(`  [${String(overall).padStart(4)}/${todo.length}] ${stock.symbol.padEnd(16)} ⟳ fetching…`);

    const sector = fetchSector(stock.symbol);

    if (sector) {
      progress.processed[stock.symbol] = sector;
      totalFilled++;
      process.stdout.write(`\r  [${String(overall).padStart(4)}/${todo.length}] ${stock.symbol.padEnd(16)} ✅ ${sector}\n`);
    } else {
      progress.processed[stock.symbol] = 'NOT_FOUND';
      process.stdout.write(`\r  [${String(overall).padStart(4)}/${todo.length}] ${stock.symbol.padEnd(16)} ⚠️  not on Screener.in\n`);
    }

    // Delay between requests (skip after last stock in batch)
    if (j < batch.length - 1) await sleep(REQUEST_DELAY);
  }

  // Save progress after every batch
  const { stillUnknown } = applyAndSave();
  console.log(`\n  ✓ Batch ${batchNum} saved — filled so far: ${totalFilled} | still unknown: ${stillUnknown}\n`);

  // Pause between batches (skip after last batch)
  if (batchEnd < todo.length) {
    process.stdout.write(`  ⏸  Pausing ${BATCH_PAUSE / 1000}s before next batch…`);
    await sleep(BATCH_PAUSE);
    process.stdout.write('\r                                               \r');
  }
}

// Final save + stats
applyAndSave();
printFinalStats();
JSEOF
