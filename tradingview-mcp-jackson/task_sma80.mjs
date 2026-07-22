import { captureScreenshot } from './src/core/capture.js';
import { clearAll } from './src/core/drawing.js';
import { manageIndicator } from './src/core/chart.js';

async function main() {
  console.log('1. Taking screenshot...');
  const shot = await captureScreenshot({ region: 'full' });
  console.log('   Screenshot saved:', shot.file_path);

  console.log('2. Removing all drawings...');
  const cleared = await clearAll();
  console.log('   Result:', cleared);

  console.log('3. Adding SMA 80...');
  const added = await manageIndicator({
    action: 'add',
    indicator: 'Moving Average',
    inputs: { length: 80 },
  });
  console.log('   Result:', added);

  process.exit(0);
}

main().catch(err => { console.error(err); process.exit(1); });
