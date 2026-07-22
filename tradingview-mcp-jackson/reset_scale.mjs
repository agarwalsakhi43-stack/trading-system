import CDP from 'chrome-remote-interface';

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });

  // Double-click on the right price scale to auto-fit
  const x = 1380, y = 430;
  const base = { x, y, button: 'left', buttons: 1, modifiers: 0 };

  await client.Input.dispatchMouseEvent({ type: 'mousePressed', clickCount: 2, ...base });
  await sleep(50);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', clickCount: 2, ...base });
  await sleep(300);
  // Second click of double-click
  await client.Input.dispatchMouseEvent({ type: 'mousePressed', clickCount: 2, ...base });
  await sleep(50);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', clickCount: 2, ...base });

  await sleep(800);
  console.log('Done resetting scale');
  await client.close();
}

main().catch(console.error);
