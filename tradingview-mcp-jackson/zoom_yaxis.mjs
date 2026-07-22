import CDP from 'chrome-remote-interface';

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  const resp = await fetch('http://localhost:9222/json/list');
  const list = await resp.json();
  const target = list.find(t => t.type === 'page' && /tradingview/.test(t.url));
  const client = await CDP({ host: 'localhost', port: 9222, target: target.id });

  // Price scale is on the RIGHT side
  // From earlier: pane x=56, y=42, w=1293, h=776
  // Price axis is to the right of the chart: around x=1350-1420
  const priceAxisX = 1380;
  const chartMidY = 42 + 776 / 2; // mid-height of chart

  // Scroll UP on the price scale to zoom in (compress the Y range)
  // Each scroll tick zooms the price scale
  for (let i = 0; i < 15; i++) {
    await client.Input.dispatchMouseEvent({
      type: 'mouseWheel',
      x: priceAxisX,
      y: chartMidY,
      deltaX: 0,
      deltaY: -120,  // scroll up = zoom in on price scale
      modifiers: 0
    });
    await sleep(80);
  }

  console.log('Zoomed Y-axis. Taking screenshot...');
  await sleep(500);
  await client.close();
}

main().catch(console.error);
