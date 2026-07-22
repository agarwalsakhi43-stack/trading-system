import CDP from 'chrome-remote-interface';

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });

  // Price axis is at the right side: x~1380, y center of chart ~430
  const priceAxisX = 1380;
  const midY = 430;

  // Scroll up (negative deltaY) on the price axis to zoom in (compress range)
  console.log('Zooming in on Y-axis...');
  for (let i = 0; i < 20; i++) {
    await client.Input.dispatchMouseEvent({
      type: 'mouseWheel',
      x: priceAxisX,
      y: midY,
      deltaX: 0,
      deltaY: -120,
      modifiers: 0,
      pointerType: 'mouse',
    });
    await sleep(60);
  }

  await sleep(500);
  console.log('Done zooming.');
  await client.close();
}

main().catch(console.error);
