// Records the PDF trailer in one take from the running trailer server.
//
//   node scripts/pdf_trailer/record.mjs <state.json> <file.pdf> <out_dir>
//
// Clara opens the composer, writes a line, a PDF flies into the drop area,
// she posts, the post appears with the file row, and "Vorschau" opens the
// pages in the lightbox. Writes the screencast frames and frames.json.
import { chromium } from "playwright";
import fs from "fs";
import path from "path";

const BASE = process.env.TRAILER_BASE || "http://localhost:4078";
const [state, pdf, out] = process.argv.slice(2);
const FRAMES = path.join(out, "frames");
fs.rmSync(FRAMES, { recursive: true, force: true });
fs.mkdirSync(FRAMES, { recursive: true });

const TEXT = "Das Programm für unser Sommerfest steht. Alles Wichtige steht im PDF.";

// what nobody should see: the dev toolbar, the notification banner, the rail
// of real members from the database copy, and the empty-feed hint
const CSS = `
#web-notify, #tidewave-toolbar, body > iframe, #rail-blocks, #feed-filter-link, #feed-other-formats,
#feed-body > div > p, footer, div:has(> #feed-page-size) { display: none !important; }
#tz-cursor { position: fixed; left: 0; top: 0; width: 28px; height: 28px; z-index: 2147483647; pointer-events: none; transform: translate(-3px,-2px); }
.tz-ring { position: fixed; width: 46px; height: 46px; margin: -23px 0 0 -23px; border-radius: 50%; border: 3px solid rgba(37,88,217,.9);
  z-index: 2147483646; pointer-events: none; animation: tzRing .55s ease-out forwards; }
@keyframes tzRing { from { transform: scale(.3); opacity: 1 } to { transform: scale(1.5); opacity: 0 } }
#tz-file { position: fixed; z-index: 2147483645; pointer-events: none; display: flex; align-items: center; gap: 10px;
  padding: 10px 14px 10px 10px; background: #fff; border-radius: 12px; box-shadow: 0 12px 30px rgba(15,23,42,.25);
  font: 600 14px system-ui, sans-serif; color: #0f172a; transition: opacity .3s; }
#tz-file .tz-doc { width: 34px; height: 44px; border-radius: 4px; background: #fff; border: 1px solid #cbd5e1; position: relative; }
#tz-file .tz-doc::after { content: "PDF"; position: absolute; left: 3px; bottom: 4px; font: 700 9px system-ui; color: #b91c1c; }
#tz-file .tz-doc::before { content: ""; position: absolute; left: 0; right: 0; top: 0; height: 6px; background: #1d4ed8; border-radius: 4px 4px 0 0; }
`;

const browser = await chromium.launch({ channel: "chrome", args: ["--force-device-scale-factor=1.5"] });
const ctx = await browser.newContext({
  storageState: state,
  viewport: { width: 1280, height: 720 },
  deviceScaleFactor: 1.5,
  locale: "de-DE",
  extraHTTPHeaders: { "Accept-Language": "de-DE,de" },
});
const page = await ctx.newPage();
await page.goto(`${BASE}/feed`, { waitUntil: "networkidle" });
await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch (e) {} });
await page.reload({ waitUntil: "networkidle" });
await page.waitForFunction(() => document.querySelector(".phx-connected"));
await page.addStyleTag({ content: CSS });
await page.evaluate(() => window.scrollTo(0, 0));

// ---- a visible pointer driven by real mouse events
await page.evaluate(() => {
  const c = document.createElement("div");
  c.id = "tz-cursor";
  c.innerHTML = '<svg viewBox="0 0 24 24" width="28" height="28"><path d="M3 2 L3 19 L7.5 15 L10.5 22 L13.5 20.7 L10.6 14 L17 14 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
  c.style.left = "1100px"; c.style.top = "600px";
  document.body.appendChild(c);
  document.addEventListener("mousemove", (e) => { c.style.left = e.clientX + "px"; c.style.top = e.clientY + "px"; }, true);
  document.addEventListener("mousedown", (e) => {
    if (e.target.closest && e.target.closest("[contenteditable=true]")) return;
    const r = document.createElement("div"); r.className = "tz-ring"; r.style.left = e.clientX + "px"; r.style.top = e.clientY + "px";
    document.body.appendChild(r);
  }, true);
});
let cx = 1100, cy = 600;
await page.mouse.move(cx, cy);
const ez = (t) => (t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2);
const glide = async (x, y, ms = 700, onStep) => {
  const n = Math.max(10, Math.round(ms / 16)), x0 = cx, y0 = cy;
  for (let i = 1; i <= n; i++) {
    const k = ez(i / n), px = x0 + (x - x0) * k, py = y0 + (y - y0) * k;
    await page.mouse.move(px, py);
    if (onStep) await onStep(px, py);
    await page.waitForTimeout(16);
  }
  cx = x; cy = y;
};
const clickAt = async (x, y, ms) => { await glide(x, y, ms); await page.waitForTimeout(160); await page.mouse.down(); await page.waitForTimeout(80); await page.mouse.up(); };
const centre = async (loc) => { const b = await loc.boundingBox(); return [b.x + b.width / 2, b.y + b.height / 2]; };

// ---- the screencast
const cdp = await ctx.newCDPSession(page);
let n = 0;
const frames = [];
cdp.on("Page.screencastFrame", ({ data, metadata, sessionId }) => {
  const f = path.join(FRAMES, `f${String(n++).padStart(5, "0")}.jpg`);
  fs.writeFileSync(f, Buffer.from(data, "base64"));
  frames.push([f, metadata.timestamp]);
  cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
});
const marks = {};
const mark = (name) => { marks[name] = Date.now() / 1000; };

await cdp.send("Page.startScreencast", { format: "jpeg", quality: 92, maxWidth: 1920, maxHeight: 1080 });
await page.waitForTimeout(900);
mark("start");

// 1. open the composer and write
await clickAt(...(await centre(page.locator("#open-composer"))), 900);
await page.waitForSelector("#composer-form", { state: "visible" });
await page.waitForTimeout(700);
const editor = page.locator("#composer-form [contenteditable=true]:visible").first();
const eb = await editor.boundingBox();
await clickAt(eb.x + 40, eb.y + 30, 500);
await page.keyboard.type(TEXT, { delay: 34 });
await page.waitForTimeout(600);

// 2. a PDF comes in from the right and is let go over the drop area
const zone = page.locator("#composer-drop [data-drop-full]");
await zone.scrollIntoViewIfNeeded();
await page.waitForTimeout(300);
const [zx, zy] = await centre(zone);
await page.evaluate(([x, y]) => {
  const f = document.createElement("div");
  f.id = "tz-file";
  f.innerHTML = '<span class="tz-doc"></span><span>Sommerfest-Programm.pdf</span>';
  f.style.left = x + "px"; f.style.top = y + "px";
  document.body.appendChild(f);
}, [1320, 620]);
cx = 1330; cy = 640;
await page.mouse.move(cx, cy);
let dragging = false;
await glide(zx, zy, 1500, async (px, py) => {
  await page.evaluate(([x, y]) => { const f = document.querySelector("#tz-file"); f.style.left = x - 20 + "px"; f.style.top = y - 20 + "px"; }, [px, py]);
  if (!dragging && Math.hypot(px - zx, py - zy) < 260) {
    dragging = true;
    await page.evaluate(() => document.querySelector("#composer-form").classList.add("is-dragging"));
  }
});
await page.waitForTimeout(500);
await page.evaluate(() => {
  document.querySelector("#composer-form").classList.remove("is-dragging");
  const f = document.querySelector("#tz-file"); f.style.opacity = 0; setTimeout(() => f.remove(), 350);
});
await page.setInputFiles("#composer-pick", pdf);
await page.waitForSelector("[data-attachment-chip]", { timeout: 20000 });
await page.waitForTimeout(1400);

// 3. post; the post waits for its preview pages
const submit = page.locator('#composer-form button[type="submit"]:visible').last();
await submit.scrollIntoViewIfNeeded();
await page.waitForTimeout(300);
await clickAt(...(await centre(submit)), 900);
await page.waitForTimeout(400);
await page.evaluate(() => window.scrollTo({ top: 0, behavior: "smooth" }));
// the file was ready before the click, so the post appears at once
await page.waitForSelector("[data-post-files]", { timeout: 90000 });
await page.waitForTimeout(1800);

// 4. the preview: the pages in the lightbox
const preview = page.locator("[data-post-files] a", { hasText: "Vorschau" }).first();
await preview.scrollIntoViewIfNeeded();
await page.waitForTimeout(400);
await clickAt(...(await centre(preview)), 1000);
await page.waitForTimeout(1700);
for (let i = 0; i < 2; i++) {
  await clickAt(...(await centre(page.locator("[data-lb-next]"))), 600);
  await page.waitForTimeout(1500);
}
await page.keyboard.press("Escape");
await page.waitForTimeout(900);
mark("end");

await cdp.send("Page.stopScreencast");
fs.writeFileSync(path.join(out, "frames.json"), JSON.stringify({ frames, marks }));
console.log("frames", frames.length, "wait", (marks.wait_end - marks.wait_start).toFixed(1), "s");
await browser.close();
