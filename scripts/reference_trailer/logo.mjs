// Draws the white vutuv logo the trailer's corner and end show, from the SVG in
// priv/static/images, the way scripts/teaser/render_assets.mjs does.
//
//   node scripts/reference_trailer/logo.mjs <out.png>
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = process.argv[2];
const svg = fs.readFileSync(path.join(root, "priv/static/images/vutuv-logo.svg")).toString("base64");

const browser = await chromium.launch({ channel: "chrome" });
const page = await (await browser.newContext({ viewport: { width: 4000, height: 2000 } })).newPage();
await page.setContent(`<body style="margin:0;background:transparent"><img id="l" src="data:image/svg+xml;base64,${svg}" style="width:3800px;filter:brightness(0) invert(1)"></body>`);
await page.waitForTimeout(300);
await page.locator("#l").screenshot({ path: out, omitBackground: true });
await browser.close();
console.log("logo", out);
