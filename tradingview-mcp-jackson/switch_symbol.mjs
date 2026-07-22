import CDP from 'chrome-remote-interface';

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });

  // Open symbol search
  await client.Input.dispatchMouseEvent({ type: 'mousePressed', x: 120, y: 19, button: 'left', buttons: 1, clickCount: 1, modifiers: 0 });
  await sleep(80);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', x: 120, y: 19, button: 'left', buttons: 0, clickCount: 1, modifiers: 0 });
  await sleep(700);

  // Type to search
  for (const char of 'NSE:RELIANCE') {
    await client.Input.dispatchKeyEvent({ type: 'char', text: char });
    await sleep(60);
  }
  await sleep(1200);

  // Click the "RELIANCE / Reliance Industries Limited / NSE" row at y=328
  // From previous scan: itemInfoCell at (396, 328), description at (748, 328)
  // Click the whole row at x=500 (middle), y=328
  await client.Input.dispatchMouseEvent({ type: 'mouseMoved', x: 500, y: 328, buttons: 0 });
  await sleep(200);
  await client.Input.dispatchMouseEvent({ type: 'mousePressed', x: 500, y: 328, button: 'left', buttons: 1, clickCount: 1, modifiers: 0 });
  await sleep(100);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', x: 500, y: 328, button: 'left', buttons: 0, clickCount: 1, modifiers: 0 });
  await sleep(2500);

  console.log('Clicked RELIANCE row. Chart should now be RELIANCE.');
  await client.close();
}

main().catch(console.error);
