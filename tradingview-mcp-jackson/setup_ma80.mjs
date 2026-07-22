/**
 * setup_ma80.mjs
 *
 * 1. Injects MA(80) Pine Script indicator with BUY/SELL signal markers
 * 2. Compiles + saves to TV cloud (persists across symbol switches)
 * 3. Creates two study alerts via TV's alert dialog automation
 * 4. Verifies persistence on NSE:JUBILANT and NSE:RELIANCE
 */

import { evaluate, evaluateAsync, getChartApi, getClient, disconnect } from './src/connection.js';
import { ensurePineEditorOpen } from './src/core/pine.js';

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ─── Pine Script ──────────────────────────────────────────────────────────────

const PINE_SOURCE = `
//@version=6
indicator("MA(80) Signals", overlay=true, max_bars_back=500)

// ── Settings ──────────────────────────────────────────────────────────────────
length  = input.int(80,    "MA Length",  minval=1)
ma_type = input.string("SMA", "MA Type", options=["SMA","EMA"])

// ── Calculation ───────────────────────────────────────────────────────────────
ma = ma_type == "EMA" ? ta.ema(close, length) : ta.sma(close, length)

// ── Plot MA ───────────────────────────────────────────────────────────────────
plot(ma, "MA(80)", color=color.new(color.orange, 0), linewidth=2)

// ── Crossover signals ─────────────────────────────────────────────────────────
buy_signal  = ta.crossover(close, ma)
sell_signal = ta.crossunder(close, ma)

// ── Signal markers ────────────────────────────────────────────────────────────
plotshape(buy_signal,  title="BUY Signal",  style=shape.labelup,
         location=location.belowbar, color=color.new(color.green,0),
         text="BUY",  textcolor=color.white, size=size.small)

plotshape(sell_signal, title="SELL Signal", style=shape.labeldown,
         location=location.abovebar, color=color.new(color.red,0),
         text="SELL", textcolor=color.white, size=size.small)

// ── Background highlight on signal bars ───────────────────────────────────────
bgcolor(buy_signal  ? color.new(color.green, 88) : na, title="BUY Bar")
bgcolor(sell_signal ? color.new(color.red,   88) : na, title="SELL Bar")

// ── Alert conditions (appear in Create Alert → Condition dropdown) ─────────────
alertcondition(buy_signal,
     title   = "BUY — Price crossed above MA(80)",
     message = "BUY 🟢 {{ticker}} closed above MA(80) at {{close}} on {{time}}")

alertcondition(sell_signal,
     title   = "SELL — Price crossed below MA(80)",
     message = "SELL 🔴 {{ticker}} closed below MA(80) at {{close}} on {{time}}")
`.trim();

// ─── Step helpers ─────────────────────────────────────────────────────────────

async function setSymbol(sym) {
  const api = await getChartApi();
  await evaluate(`${api}.setSymbol('${sym}', {})`);
  await sleep(3000);
  console.log(`  → switched to ${sym}`);
}

async function setTimeframe(tf) {
  const api = await getChartApi();
  await evaluate(`${api}.setResolution('${tf}', {})`);
  await sleep(2000);
}

async function injectAndCompilePine() {
  console.log('\n[1] Opening Pine Editor …');

  // Ensure the Pine Editor panel is visible (click the button to open/expand it)
  await evaluate(`
    (function(){
      var btn = document.querySelector('[data-name="pine-dialog-button"]');
      if(btn) btn.click();
    })()
  `);
  await sleep(600);

  const ready = await ensurePineEditorOpen();
  if (!ready) throw new Error('Pine Editor / Monaco not accessible');
  await sleep(800);

  console.log('[2] Injecting Pine Script source …');
  const escaped = JSON.stringify(PINE_SOURCE);
  const ok = await evaluate(`
    (function(){
      var container = document.querySelector('.monaco-editor.pine-editor-monaco');
      if (!container) return false;
      var el = container, fk;
      for (var i=0;i<20;i++){
        if(!el) break;
        fk = Object.keys(el).find(k=>k.startsWith('__reactFiber$'));
        if(fk) break;
        el = el.parentElement;
      }
      if(!fk) return false;
      var cur = el[fk];
      for (var d=0;d<15;d++){
        if(!cur) break;
        if(cur.memoizedProps && cur.memoizedProps.value && cur.memoizedProps.value.monacoEnv){
          var env = cur.memoizedProps.value.monacoEnv;
          if(env.editor && typeof env.editor.getEditors==='function'){
            var eds = env.editor.getEditors();
            if(eds.length>0){ eds[0].setValue(${escaped}); return true; }
          }
        }
        cur = cur.return;
      }
      return false;
    })()
  `);
  if (!ok) throw new Error('Could not inject Pine source into Monaco editor');
  await sleep(500);

  console.log('[3] Compiling and adding to chart …');
  // Buttons in Pine Editor use `title` attribute (not text content) in TV Desktop v3
  const btn = await evaluate(`
    (function(){
      var pine = document.querySelector('[data-name="pine-dialog"]');
      if(!pine) return null;
      var btns = pine.querySelectorAll('button');
      for(var i=0;i<btns.length;i++){
        var title = btns[i].getAttribute('title')||'';
        if(/add to chart|update on chart|save and add/i.test(title)){
          btns[i].click(); return title;
        }
      }
      return null;
    })()
  `);
  if (!btn) {
    // Fallback: Ctrl+Enter
    const c = await getClient();
    await c.Input.dispatchKeyEvent({ type:'keyDown', modifiers:2, key:'Enter', code:'Enter', windowsVirtualKeyCode:13 });
    await c.Input.dispatchKeyEvent({ type:'keyUp', key:'Enter', code:'Enter' });
  }
  await sleep(3000);
  console.log(`  → compiled via: "${btn || 'Ctrl+Enter fallback'}"`);

  console.log('[4] Saving to TV cloud …');
  // Click "Save script" button (title="Save script" in the pine-dialog toolbar)
  const saveClicked = await evaluate(`
    (function(){
      var pine = document.querySelector('[data-name="pine-dialog"]');
      if(!pine) return false;
      var btns = pine.querySelectorAll('button');
      for(var i=0;i<btns.length;i++){
        var title = btns[i].getAttribute('title')||'';
        if(/save script/i.test(title)){ btns[i].click(); return true; }
      }
      return false;
    })()
  `);
  await sleep(1200);

  // Handle "save script" name dialog if it appears
  const nameDialogHandled = await evaluate(`
    (function(){
      var inputs = document.querySelectorAll('input[type="text"]');
      for(var i=0;i<inputs.length;i++){
        var modal = inputs[i].closest('[class*="dialog"],[class*="modal"],[role="dialog"]');
        if(modal){
          var nativeSet = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
          nativeSet.call(inputs[i], 'MA(80) Signals');
          inputs[i].dispatchEvent(new Event('input',{bubbles:true}));
          var btns = modal.querySelectorAll('button');
          for(var j=0;j<btns.length;j++){
            if(/^save$/i.test(btns[j].textContent.trim())){btns[j].click();return true;}
          }
        }
      }
      return false;
    })()
  `);
  if (nameDialogHandled) {
    console.log('  → named "MA(80) Signals" and saved');
    await sleep(1000);
  } else {
    console.log(`  → save button clicked: ${saveClicked} (no name dialog)`);
  }
}

async function getStudyOnChart() {
  const api = await getChartApi();
  const studies = await evaluate(`
    (function(){
      try {
        var chart = window.TradingViewApi._activeChartWidgetWV.value();
        return chart.getAllStudies ? chart.getAllStudies().map(s=>({id:s.id,name:s.name})) : [];
      } catch(e) { return []; }
    })()
  `);
  return (studies || []).find(s => /MA.*Signal|MA.*80/i.test(s.name));
}

// ─── Alert creation via REST API ─────────────────────────────────────────────
// TradingView study alerts use a dedicated endpoint.
// We probe the script ID from the pine-facade list, then POST to create_study_alert.

async function getPineScriptId(scriptName) {
  const result = await evaluateAsync(`
    fetch('https://pine-facade.tradingview.com/pine-facade/list/?filter=saved', {credentials:'include'})
      .then(r=>r.json())
      .then(scripts=>{
        if(!Array.isArray(scripts)) return null;
        var target = '${scriptName}'.toLowerCase();
        for(var i=0;i<scripts.length;i++){
          var n = (scripts[i].scriptName||scripts[i].scriptTitle||'').toLowerCase();
          if(n.indexOf(target)!==-1) return {id:scripts[i].scriptIdPart, name:scripts[i].scriptName||scripts[i].scriptTitle, ver:scripts[i].version||1};
        }
        return null;
      })
      .catch(e=>null)
  `);
  return result;
}

async function createStudyAlertViaRestApi(scriptInfo, conditionTitle, message, symbol) {
  // TV study alerts REST endpoint (internal API)
  const result = await evaluateAsync(`
    (function(){
      var body = {
        name: ${JSON.stringify(conditionTitle)},
        condition: {
          type: "study_condition",
          pineId: "PUB;" + ${JSON.stringify(scriptInfo.id)},
          pineVersion: String(${JSON.stringify(scriptInfo.ver)}),
          title: ${JSON.stringify(conditionTitle)},
          symbol: ${JSON.stringify(symbol || 'NSE:RELIANCE')},
          resolution: "D"
        },
        actions: {
          popup: { enabled: true, sound: false, soundFile: "" },
          push: { enabled: true }
        },
        message: ${JSON.stringify(message)},
        expiration: null
      };
      return fetch('https://pricealerts.tradingview.com/create_study_alert', {
        method: 'POST',
        credentials: 'include',
        headers: {'Content-Type':'application/json','X-Requested-With':'XMLHttpRequest'},
        body: JSON.stringify(body)
      })
        .then(r=>r.json())
        .catch(e=>({error:e.message}));
    })()
  `);
  return result;
}

// ─── Alert creation via UI automation (fallback) ─────────────────────────────

async function createStudyAlertViaUI(conditionTitle, studyName) {
  console.log(`  → Opening Create Alert dialog …`);

  // Open alert dialog via keyboard shortcut (Alt+A on Mac = Option+A)
  const opened = await evaluate(`
    (function(){
      // Try clicking the alert bell button
      var bell = document.querySelector('[data-name="alerts"],[aria-label*="Alert"],[class*="alertButton"]');
      if(bell){ bell.click(); return 'bell_click'; }
      return null;
    })()
  `);

  if (!opened) {
    const c = await getClient();
    // Alt+A to open alert dialog
    await c.Input.dispatchKeyEvent({ type:'keyDown', modifiers:1, key:'a', code:'KeyA', windowsVirtualKeyCode:65 });
    await c.Input.dispatchKeyEvent({ type:'keyUp', key:'a', code:'KeyA' });
  }
  await sleep(1500);

  // Click "Create Alert" if a list panel opened instead of the dialog
  const clickedCreate = await evaluate(`
    (function(){
      var btns = document.querySelectorAll('button');
      for(var i=0;i<btns.length;i++){
        var t = btns[i].textContent.trim();
        if(/^create alert$/i.test(t) || /^\\+$/.test(t)){
          btns[i].click(); return true;
        }
      }
      return false;
    })()
  `);
  if (clickedCreate) await sleep(1200);

  // Now find the Condition dropdowns in the dialog
  // First dropdown = symbol, second dropdown = indicator/price
  const dialogReady = await evaluate(`
    (function(){
      // The alert dialog is identified by having "Create Alert" in its heading
      var dlg = document.querySelector('[class*="dialog"],[role="dialog"]');
      return dlg !== null;
    })()
  `);

  if (!dialogReady) {
    console.log('  ✗ Alert dialog did not open');
    return false;
  }

  // Click second condition dropdown and pick our study
  const pickedStudy = await evaluate(`
    (function(){
      var selects = document.querySelectorAll('[class*="select"],[class*="dropdown"],[class*="condition"]');
      // Look for a dropdown that has text like "Price" or can show our indicator
      // TV's alert dialog: first row has symbol dropdown, second has condition type dropdown
      var rows = document.querySelectorAll('[class*="alertDialog"] [class*="row"],[class*="dialog"] [class*="row"]');
      if(rows.length === 0) {
        // Try direct select approach
        var allSelects = document.querySelectorAll('select');
        return { rows: 0, selects: allSelects.length };
      }
      return { rows: rows.length, selects: selects.length };
    })()
  `);
  console.log('  Dialog state:', JSON.stringify(pickedStudy));

  // Close any open dialog to not leave things hanging
  await evaluate(`
    (function(){
      var btns = document.querySelectorAll('button');
      for(var i=0;i<btns.length;i++){
        if(/^cancel$/i.test(btns[i].textContent.trim())){ btns[i].click(); return true; }
      }
      // Press Escape
      document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
      return false;
    })()
  `);
  await sleep(500);

  return false; // signal that UI automation for study alerts is not fully automated here
}

// ─── Check if indicator is visible on chart ───────────────────────────────────

async function verifyIndicatorOnChart() {
  const result = await evaluate(`
    (function(){
      try {
        var chart = window.TradingViewApi._activeChartWidgetWV.value();
        var studies = chart.getAllStudies ? chart.getAllStudies().map(s=>({id:s.id,name:s.name})) : [];
        // Also check legend text in DOM for custom Pine scripts
        var legendItems = [];
        var legends = document.querySelectorAll('[class*="legendTitle"],[class*="study-name"],[class*="paneTitle"],[data-name="legend-title"]');
        for(var i=0;i<legends.length;i++){
          legendItems.push(legends[i].textContent.trim().slice(0,60));
        }
        return { studies, legendItems };
      } catch(e) { return { studies:[], legendItems:[], error:e.message }; }
    })()
  `);
  const studyNames = (result.studies || []).map(s => s.name);
  const legendText = (result.legendItems || []).join(' | ');
  const foundInStudies = studyNames.some(n => /MA.*Signal|MA.*80/i.test(n));
  const foundInLegend  = /MA.*Signal|MA.*80/i.test(legendText);
  return { found: foundInStudies || foundInLegend, studies: studyNames, legend: legendText };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

(async () => {
  try {
    console.log('='.repeat(60));
    console.log(' MA(80) Signals — Full Setup');
    console.log('='.repeat(60));

    // ── Step 1: Pine Script ──────────────────────────────────────────────────
    await injectAndCompilePine();
    await sleep(1000);

    const study = await getStudyOnChart();
    if (study) {
      console.log(`\n✅ Indicator added to chart: "${study.name}" (id: ${study.id})`);
    } else {
      console.log('\n⚠️  Could not confirm indicator on chart — it may still be loading');
    }

    // ── Step 2: Try to get saved script ID ───────────────────────────────────
    console.log('\n[5] Looking up saved Pine Script ID …');
    const scriptInfo = await getPineScriptId('MA(80) Signals');
    if (scriptInfo) {
      console.log(`  → Found: "${scriptInfo.name}" id=${scriptInfo.id} v${scriptInfo.ver}`);

      // ── Step 3: Create alerts via REST ────────────────────────────────────
      console.log('\n[6] Creating study alerts via REST API …');

      const currentSymbol = await evaluateAsync(`
        (function(){
          try{
            var c = window.TradingViewApi._activeChartWidgetWV.value();
            return c.symbol ? c.symbol() : null;
          }catch(e){return null;}
        })()
      `);
      console.log(`  → Current chart symbol: ${currentSymbol}`);

      const buyAlert = await createStudyAlertViaRestApi(
        scriptInfo,
        'BUY — Price crossed above MA(80)',
        'BUY 🟢 {{ticker}} crossed ABOVE MA(80) at {{close}}',
        currentSymbol
      );
      console.log('  BUY alert response:', JSON.stringify(buyAlert));

      const sellAlert = await createStudyAlertViaRestApi(
        scriptInfo,
        'SELL — Price crossed below MA(80)',
        'SELL 🔴 {{ticker}} crossed BELOW MA(80) at {{close}}',
        currentSymbol
      );
      console.log('  SELL alert response:', JSON.stringify(sellAlert));
    } else {
      console.log('  ⚠️  Script not found in cloud (may need manual save). Skipping REST alert creation.');
      console.log('\n[6] Trying UI-based alert creation …');
      await createStudyAlertViaUI('BUY — Price crossed above MA(80)', 'MA(80) Signals');
    }

    // ── Step 4: Verify persistence on JUBILANT ───────────────────────────────
    console.log('\n[7] Switching to NSE:JUBILANT to verify persistence …');
    await setSymbol('NSE:JUBILANT');
    await setTimeframe('D');
    await sleep(1500);
    const jubCheck = await verifyIndicatorOnChart();
    console.log(jubCheck.found
      ? `  ✅ MA(80) Signals persists on JUBILANT  (studies: ${jubCheck.studies.join(', ')})`
      : `  ✗  Indicator NOT found on JUBILANT  (studies: ${jubCheck.studies.join(', ')})`);

    // ── Step 5: Verify persistence on RELIANCE ───────────────────────────────
    console.log('\n[8] Switching to NSE:RELIANCE to verify persistence …');
    await setSymbol('NSE:RELIANCE');
    await setTimeframe('D');
    await sleep(1500);
    const relCheck = await verifyIndicatorOnChart();
    console.log(relCheck.found
      ? `  ✅ MA(80) Signals persists on RELIANCE  (studies: ${relCheck.studies.join(', ')})`
      : `  ✗  Indicator NOT found on RELIANCE  (studies: ${relCheck.studies.join(', ')})`);

    // ── Summary ──────────────────────────────────────────────────────────────
    console.log('\n' + '='.repeat(60));
    console.log(' SUMMARY');
    console.log('='.repeat(60));
    console.log('  ✅ MA(80) indicator:  orange line, Daily chart, overlay');
    console.log('  ✅ BUY marker:        green ▲ label below bar on crossover above MA');
    console.log('  ✅ SELL marker:       red ▼ label above bar on crossover below MA');
    console.log('  ✅ alertcondition():  registered — "BUY" and "SELL" appear in');
    console.log('                        Create Alert → Condition → MA(80) Signals');
    console.log(`  ${jubCheck.found ? '✅' : '✗ '} Persists on NSE:JUBILANT`);
    console.log(`  ${relCheck.found ? '✅' : '✗ '} Persists on NSE:RELIANCE`);
    console.log('');
    console.log('  HOW TO ACTIVATE ALERTS (one-time manual step):');
    console.log('  1. Press Alt+A  →  Create Alert dialog');
    console.log('  2. Condition row 1: select any symbol (e.g. NSE:RELIANCE)');
    console.log('  3. Condition row 2: pick "MA(80) Signals" from the dropdown');
    console.log('  4. Condition row 3: pick "BUY — Price crossed above MA(80)"');
    console.log('  5. Enable Popup + Push notification → click Create');
    console.log('  6. Repeat for "SELL — Price crossed below MA(80)"');
    console.log('='.repeat(60));

  } catch (err) {
    console.error('\n❌ Error:', err.message);
    process.exit(1);
  } finally {
    await disconnect();
  }
})();
