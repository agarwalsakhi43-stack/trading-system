import CDP from 'chrome-remote-interface';

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });

  // Price scale center: x=1385, y=430 (CSS pixels, verified via getBoundingClientRect)
  const x = 1385, y = 500;

  // First click the price scale to focus/activate it
  await client.Input.dispatchMouseEvent({ type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1, modifiers: 0 });
  await sleep(100);
  await client.Input.dispatchMouseEvent({ type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1, modifiers: 0 });
  await sleep(300);

  // Scroll DOWN on price scale to zoom OUT (expand Y range)
  // +deltaY = scroll down = zoom out on price axis
  console.log('Zooming OUT on Y-axis (40 steps)...');
  for (let i = 0; i < 40; i++) {
    await client.Input.dispatchMouseEvent({
      type: 'mouseWheel',
      x,
      y,
      deltaX: 0,
      deltaY: 100,
      modifiers: 0,
      pointerType: 'mouse',
    });
    await sleep(80);
  }

  await sleep(800);
  console.log('Done.');
  await client.close();
}

main().catch(console.error);
