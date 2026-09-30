// Records the Arbeitszeugnis trailer in one take from the running trailer server.
//
//   node scripts/reference_trailer/record.mjs <state.json> <zeugnis.pdf> <out_dir>
//
// Friedhelm adds his Zeugnis (title, employer, the PDF flies into the drop
// area), saves, presses "Zeugnis entschlüsseln", waits while the model reads
// it, and opens the result. The wait is minutes of real inference; render.py
// runs it by in seconds. Writes <out_dir>/rec/take/: the screencast frames,
// frames.json, marks.json (the moments render.py cuts on) and pos.json (where,
// in frame pixels, the camera pushes in).
import { chromium } from "playwright";
import fs from "fs";
import path from "path";

const BASE = process.env.TRAILER_BASE || "http://localhost:4079";
const [state, pdf, out] = process.argv.slice(2);
const TAKE = path.join(out, "rec", "take");
const FRAMES = path.join(TAKE, "frames");
fs.rmSync(FRAMES, { recursive: true, force: true });
fs.mkdirSync(FRAMES, { recursive: true });

// what nobody should see: the dev toolbar, the notification banner, the footer
const CSS = `
#web-notify, #tidewave-toolbar, body > iframe, footer { display: none !important; }
[data-tidewave], .tidewave-toolbar { display: none !important; }
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

// every page load needs the styling and the pointer again
let cx = 1100, cy = 600;
const dress = async () => {
  await page.addStyleTag({ content: CSS });
  await page.evaluate(([x, y]) => {
    const c = document.createElement("div");
    c.id = "tz-cursor";
    c.innerHTML = '<svg viewBox="0 0 24 24" width="28" height="28"><path d="M3 2 L3 19 L7.5 15 L10.5 22 L13.5 20.7 L10.6 14 L17 14 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
    c.style.left = x + "px"; c.style.top = y + "px";
    document.body.appendChild(c);
    document.addEventListener("mousemove", (e) => { c.style.left = e.clientX + "px"; c.style.top = e.clientY + "px"; }, true);
    document.addEventListener("mousedown", (e) => {
      const r = document.createElement("div"); r.className = "tz-ring"; r.style.left = e.clientX + "px"; r.style.top = e.clientY + "px";
      document.body.appendChild(r);
    }, true);
  }, [cx, cy]);
};
page.on("load", () => { dress().catch(() => {}); });

await page.goto(`${BASE}/settings/job_references`, { waitUntil: "networkidle" });
await page.evaluate(() => window.scrollTo(0, 0));
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
const clickOn = async (loc, ms = 800) => { await loc.scrollIntoViewIfNeeded(); await page.waitForTimeout(250); await clickAt(...(await centre(loc)), ms); };
const smoothScroll = async (dy, ms) => {
  const n = Math.round(ms / 16), y0 = await page.evaluate(() => window.scrollY);
  for (let i = 1; i <= n; i++) {
    await page.evaluate((y) => window.scrollTo(0, y), y0 + dy * ez(i / n));
    await page.waitForTimeout(16);
  }
};

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
// frame pixels are 1.5x the page's CSS pixels
const pos = {};
const spot = async (name, loc) => { const b = await loc.boundingBox(); pos[name] = [(b.x + b.width / 2) * 1.5, (b.y + b.height / 2) * 1.5]; };

await cdp.send("Page.startScreencast", { format: "jpeg", quality: 92, maxWidth: 1920, maxHeight: 1080 });
await page.waitForTimeout(1200);
mark("start");

// 1. add a Zeugnis
await Promise.all([page.waitForURL(/\/new$/), clickOn(page.locator('main a[href$="/job_references/new"]').first(), 900)]);
await page.waitForLoadState("networkidle");
await page.waitForTimeout(300);
mark("form");
await clickOn(page.locator("#job_reference_title"), 400);
await page.keyboard.type("Lagermeister", { delay: 25 });
await clickOn(page.locator("#job_reference_employer"), 350);
await page.keyboard.type("Eisenwarenhandlung Großkopf Söhne KG", { delay: 15 });
mark("typed");
await page.waitForTimeout(200);
await clickOn(page.locator('input[name="job_reference[owner_confirmation]"]'), 450);
await page.waitForTimeout(250);

// 2. the PDF comes in from the right and is let go over the drop area
const zone = page.locator(".upload-drop").first();
await zone.scrollIntoViewIfNeeded();
await page.waitForTimeout(300);
const [zx, zy] = await centre(zone);
mark("drag");
await page.evaluate(([x, y]) => {
  const f = document.createElement("div");
  f.id = "tz-file";
  f.innerHTML = '<span class="tz-doc"></span><span>Arbeitszeugnis.pdf</span>';
  f.style.left = x + "px"; f.style.top = y + "px";
  document.body.appendChild(f);
}, [zx + 380, zy + 120]);
cx = zx + 400; cy = zy + 140;
await page.mouse.move(cx, cy);
await glide(zx, zy, 1000, async (px, py) => {
  await page.evaluate(([x, y]) => { const f = document.querySelector("#tz-file"); f.style.left = x - 20 + "px"; f.style.top = y - 20 + "px"; }, [px, py]);
});
await page.waitForTimeout(300);
await page.evaluate(() => { const f = document.querySelector("#tz-file"); f.style.opacity = 0; setTimeout(() => f.remove(), 350); });
await page.setInputFiles("#job_reference_document", pdf);
mark("attached");
await page.waitForTimeout(750);

// 3. save
await Promise.all([page.waitForURL(/\/job_references$/), clickOn(page.locator('main button:has-text("Speichern")'), 900)]);
await page.waitForLoadState("networkidle");
await page.waitForFunction(() => document.querySelector(".phx-connected"));
await page.waitForTimeout(1400);
mark("saved");

// 4. the check: minutes of inference, run by quickly in the film
const button = page.locator('main button:has-text("Zeugnis entschlüsseln")');
await spot("card", button);
await clickOn(button, 900);
mark("checking");
await page.waitForSelector('main a[href$="/check"]', { timeout: 15 * 60_000 });
mark("done");
await page.waitForTimeout(1000);

// 5. the result
// LiveView navigates this one, so wait for the document, not the load event
await Promise.all([
  page.waitForURL(/\/check$/, { waitUntil: "domcontentloaded" }),
  clickOn(page.locator('main a[href$="/check"]').first(), 900),
]);
await page.waitForLoadState("networkidle");
await page.waitForTimeout(900);
mark("result");
await smoothScroll(700, 3000);
await page.waitForTimeout(1300);
await smoothScroll(1700, 6500);
await page.waitForTimeout(1600);
mark("end");

await cdp.send("Page.stopScreencast");
fs.writeFileSync(path.join(TAKE, "frames.json"), JSON.stringify({ frames }));
fs.writeFileSync(path.join(TAKE, "marks.json"), JSON.stringify(marks));
fs.writeFileSync(path.join(TAKE, "pos.json"), JSON.stringify(pos));
console.log("frames", frames.length, "marks", Object.keys(marks).join(" "));
await browser.close();
