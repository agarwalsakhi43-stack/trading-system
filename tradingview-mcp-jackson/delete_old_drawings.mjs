import CDP from 'chrome-remote-interface';

// Old drawing Y positions (calculated from price range 891-5415, pane y=42, h=776)
// Formula: yBottom - (price - priceMin)/(priceMax - priceMin) * h
const paneY = 42, paneH = 776;
const priceMin = 891, priceMax = 5415;
const yBottom = paneY + paneH;
const chartX = 703;

function priceToY(p) {
  return Math.round(yBottom - (p - priceMin) / (priceMax - priceMin) * paneH);
}

const targets = [
  { price: 5185, label: 'Resistance 5185' },
  { price: 4800, label: 'Support 4800' },
  { price: 4450, label: 'Support 4450' },
  { price: 3852, label: 'Historical SR 3852' },
  { price: 3168, label: 'Historical SR 3168' },
];

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function dispatchMouseClick(client, x, y) {
  const base = { x, y, button: 'left', buttons: 1, clickCount: 1, modifiers: 0 };
  await client.Input.dispatchMouseEvent({ type: 'mousePressed', ...base });
  await sleep(50);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', ...base });
}

async function dispatchKey(client, key, code, keyCode) {
  await client.Input.dispatchKeyEvent({ type: 'keyDown', key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode });
  await sleep(30);
  await client.Input.dispatchKeyEvent({ type: 'keyUp', key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode });
}

async function main() {
  // Find chart target
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  if (!target) { console.error('No TradingView target'); process.exit(1); }

  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });
  await client.Input.enable?.();

  for (const t of targets) {
    const y = priceToY(t.price);
    console.log(`Clicking ${t.label} at (${chartX}, ${y})`);

    // First click to select
    await dispatchMouseClick(client, chartX, y);
    await sleep(400);

    // Press Delete to remove selected drawing
    await dispatchKey(client, 'Delete', 'Delete', 46);
    await sleep(300);

    // Press Escape to deselect
    await dispatchKey(client, 'Escape', 'Escape', 27);
    await sleep(200);
  }

  // Check remaining shapes
  const result = await client.Runtime.evaluate({
    expression: `(function(){ var c = window.TradingViewApi._activeChartWidgetWV.value(); return 'Shapes: ' + c.getAllShapes().length; })()`,
    returnByValue: true
  });
  console.log(result.result?.value);

  await client.close();
}

main().catch(console.error);
