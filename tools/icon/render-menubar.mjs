import pw from '/opt/node22/lib/node_modules/playwright/index.js'; const { chromium } = pw;
import * as icons from './icons.mjs';
// Renders the menu bar icon into its image set: <Name>.png (22 x 18 pt at 1x) and <Name>@2x.png.
const assets = process.argv[2];
const browser = await chromium.launch();
for (const [name, svg] of [['MenuBarIcon', icons.menuBarIcon]]) {
  for (const scale of [1, 2]) {
    const page = await browser.newPage({ viewport: { width: 22, height: 18 }, deviceScaleFactor: scale });
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('width="44" height="36"', 'width="22" height="18"')}</body></html>`);
    await page.screenshot({ path: `${assets}/${name}.imageset/${name}${scale === 2 ? '@2x' : ''}.png`, omitBackground: true, clip: { x: 0, y: 0, width: 22, height: 18 } });
    await page.close();
  }
}
await browser.close();
