// Background picture of the DMG install window. It has no words, so it reads the same in every language:
// the app icon goes on the left, the Applications folder on the right, the arrow between them says "drag",
// and the two guide folders sit side by side below the arrow (positions are set in make-dmg.sh).
// The window is 640 × 480 points, but the picture is larger and keeps its colour to the right and below: Finder may open
// the window wider than asked, and the tab bar, path bar and status bar (Finder settings of each Mac) take height from it.
// Everything that matters stays in the top 400 points.
// The colour is a mid tone so Finder's icon labels stay readable in both light mode (black text) and dark mode (white text).
// Render (needs Playwright; run where it's installed, not on the Mac):
//   node tools/release/dmg-background.mjs <out folder>
// writes dmg-background.png (1200 × 800), dmg-background@2x.png (2400 × 1600), dmg-guide-icon.png (512 × 512, the install guide's
// icon: a page with a question mark) and dmg-widget-icon.png (512 × 512, the widget notes' icon: the same page with the widget glyph,
// four squares). Run tools/icon/strip-png-metadata.py on them before committing.
import pw from '/opt/node22/lib/node_modules/playwright/index.js'; const { chromium } = pw;

export const width = 1200;
export const height = 800;

export const background = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <defs>
    <linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="480">
      <stop offset="0" stop-color="#7089a3"/>
      <stop offset="1" stop-color="#617a94"/>
    </linearGradient>
  </defs>
  <rect width="${width}" height="${height}" fill="url(#bg)"/>
  <g fill="none" stroke="#ffffff" stroke-opacity="0.92" stroke-linecap="round" stroke-linejoin="round">
    <path d="M252 140 H374" stroke-width="12"/>
    <path d="M358 114 L386 140 L358 166" stroke-width="12"/>
  </g>
</svg>`;

export const guideIcon = `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000000" flood-opacity="0.28"/>
    </filter>
  </defs>
  <path d="M120 40 H330 L412 122 V448 a24 24 0 0 1 -24 24 H120 a24 24 0 0 1 -24 -24 V64 a24 24 0 0 1 24 -24 Z" fill="#ffffff" filter="url(#shadow)"/>
  <path d="M330 40 V98 a24 24 0 0 0 24 24 H412 Z" fill="#dfe6ee"/>
  <circle cx="254" cy="290" r="112" fill="#3a6ea5"/>
  <path d="M212 252 a42 42 0 1 1 64 36 c-14 9 -22 18 -22 36 v8" fill="none" stroke="#ffffff" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="254" cy="368" r="17" fill="#ffffff"/>
</svg>`;

export const widgetIcon = `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000000" flood-opacity="0.28"/>
    </filter>
  </defs>
  <path d="M120 40 H330 L412 122 V448 a24 24 0 0 1 -24 24 H120 a24 24 0 0 1 -24 -24 V64 a24 24 0 0 1 24 -24 Z" fill="#ffffff" filter="url(#shadow)"/>
  <path d="M330 40 V98 a24 24 0 0 0 24 24 H412 Z" fill="#dfe6ee"/>
  <g fill="#3a6ea5">
    <rect x="152" y="190" width="92" height="92" rx="22"/>
    <rect x="264" y="190" width="92" height="92" rx="22"/>
    <rect x="152" y="302" width="92" height="92" rx="22"/>
    <rect x="264" y="302" width="92" height="92" rx="22"/>
  </g>
</svg>`;

const outDir = process.argv[2];
if (outDir) {
  const browser = await chromium.launch();
  for (const [scale, name] of [[1, 'dmg-background.png'], [2, 'dmg-background@2x.png']]) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
    await page.setContent(`<html><body style="margin:0">${background}</body></html>`);
    await page.screenshot({ path: `${outDir}/${name}`, clip: { x: 0, y: 0, width, height } });
    await page.close();
  }
  for (const [icon, name] of [[guideIcon, 'dmg-guide-icon.png'], [widgetIcon, 'dmg-widget-icon.png']]) {
    const page = await browser.newPage({ viewport: { width: 512, height: 512 }, deviceScaleFactor: 1 });
    await page.setContent(`<html><body style="margin:0;background:transparent">${icon}</body></html>`);
    await page.screenshot({ path: `${outDir}/${name}`, omitBackground: true, clip: { x: 0, y: 0, width: 512, height: 512 } });
    await page.close();
  }
  await browser.close();
}
