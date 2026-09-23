// Shared helpers for the teaser recorder: browser contexts, the build-up styles,
// the CDP screencast, and a visible mouse pointer driven by real mouse events.
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, "../..");
export const BASE = process.env.TEASER_BASE || "http://localhost:4077";

export function loadContent(lang) {
  return JSON.parse(fs.readFileSync(path.join(HERE, `content.${lang}.json`), "utf8"));
}

// what nobody should see in the film: the dev toolbar, the browser-notification
// banner, and the "draft deleted" strip a discarded draft leaves behind
export const CSS = `
#web-notify, #tidewave-toolbar, body > iframe, #composer-discarded { display: none !important; }
.tz-h { opacity: 0; }
.tz-in { animation: tzIn .75s cubic-bezier(.2,.8,.2,1) forwards; }
.tz-pop { animation: tzPop .6s cubic-bezier(.3,1.5,.5,1) forwards; }
.tz-out { animation: tzOut .45s ease-in forwards; }
.tz-beat { animation: tzBeat .6s cubic-bezier(.3,1.6,.5,1); display: inline-block; }
.tz-cover { animation: tzCover 1.1s cubic-bezier(.3,.7,.2,1) forwards; }
@keyframes tzIn { from { opacity: 0; transform: translateY(22px) } to { opacity: 1; transform: none } }
@keyframes tzPop { from { opacity: 0; transform: scale(.4) } to { opacity: 1; transform: none } }
@keyframes tzOut { from { opacity: 1; transform: none } to { opacity: 0; transform: translateY(-12px) } }
@keyframes tzBeat { 0% { transform: scale(1) } 40% { transform: scale(1.45) } 100% { transform: scale(1) } }
@keyframes tzCover { from { opacity: 1; clip-path: inset(0 0 100% 0) } to { opacity: 1; clip-path: inset(0 0 0 0) } }
#tz-cursor { position: fixed; left: 0; top: 0; width: 28px; height: 28px; z-index: 2147483647; pointer-events: none; transform: translate(-3px,-2px); transition: opacity .4s; }
.tz-ring { position: fixed; width: 46px; height: 46px; margin: -23px 0 0 -23px; border-radius: 50%; border: 3px solid rgba(37,88,217,.9); z-index: 2147483646; pointer-events: none; animation: tzRing .55s ease-out forwards; }
@keyframes tzRing { from { transform: scale(.3); opacity: 1 } to { transform: scale(1.5); opacity: 0 } }
.tz-badge { position: absolute; top: 2px; right: 1px; min-width: 18px; height: 18px; padding: 0 5px; border-radius: 9px;
  background: #ef4444; color: #fff; font: 600 11px/18px system-ui, sans-serif; text-align: center; opacity: 0; }
`;

// in-page helpers, installed with page.evaluate (the app's CSP blocks inline <script>)
export const HELPERS = `(() => {
  window.tzAt = (ms, el, cls) => setTimeout(() => el && el.classList.add(cls), ms);
  window.tzScrollTo = (ms, y1, dur) => setTimeout(() => {
    const y0 = scrollY, s = performance.now();
    const ez = (t) => (t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2);
    const tick = () => { const t = Math.min(1, (performance.now() - s) / dur); scrollTo(0, y0 + (y1 - y0) * ez(t)); if (t < 1) setTimeout(tick, 16); };
    tick();
  }, ms);
  window.tzTop = (el) => el.getBoundingClientRect().top + scrollY;
  // the dev host never shows: every visible "localhost:4077" reads as vutuv.de
  window.tzLocalhost = () => {
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      const p = n.parentElement;
      if (!p || p.closest("script, style, [contenteditable=true], textarea")) continue;
      if (n.nodeValue.includes("localhost:4077")) n.nodeValue = n.nodeValue.replace(/(https?:\\/\\/)?localhost:4077/g, "https://vutuv.de");
    }
  };
  window.tzLocalhost();
  new MutationObserver(() => window.tzLocalhost()).observe(document.body, { subtree: true, childList: true, characterData: true });
  // unread badges left over from earlier takes stay out of every scene
  window.tzHideCounts = () => document.querySelectorAll("header a span, nav a span").forEach((s) => {
    if (s.children.length === 0 && /^\\d+$/.test(s.textContent.trim())) s.style.display = "none";
  });
})()`;

export async function newContext(browser, lang, state, extra = {}) {
  const c = loadContent(lang);
  return browser.newContext({
    ...(state ? { storageState: state } : {}),
    locale: lang === "de" ? "de-DE" : "en-GB",
    extraHTTPHeaders: { "Accept-Language": c.accept_language },
    viewport: { width: 1280, height: 720 },
    deviceScaleFactor: 1.5,
    ...extra,
  });
}

export async function dress(page) {
  await page.addStyleTag({ content: CSS });
  await page.evaluate(HELPERS);
}

export async function open(ctx, url, { live = true } = {}) {
  const page = await ctx.newPage();
  await page.goto(BASE + url, { waitUntil: "networkidle" });
  if (live) await page.waitForFunction(() => document.querySelector(".phx-connected"), null, { timeout: 15000 }).catch(() => {});
  await dress(page);
  await page.evaluate(() => { window.tzHideCounts(); window.scrollTo(0, 0); });
  return page;
}

// Records the page with the CDP screencast. Frames carry their own timestamps;
// render/timeline.py turns them into a constant-rate clip.
export async function record(page, out, body) {
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const cdp = await page.context().newCDPSession(page);
  let n = 0;
  const frames = [];
  cdp.on("Page.screencastFrame", ({ data, metadata, sessionId }) => {
    const f = path.join(out, `f${String(n++).padStart(5, "0")}.jpg`);
    fs.writeFileSync(f, Buffer.from(data, "base64"));
    frames.push([f, metadata.timestamp]);
    cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
  });
  await cdp.send("Page.startScreencast", { format: "jpeg", quality: 92, maxWidth: 1920, maxHeight: 1080 });
  await page.waitForTimeout(400);
  await body();
  await cdp.send("Page.stopScreencast");
  fs.writeFileSync(path.join(out, "frames.json"), JSON.stringify({ frames }));
  console.log(path.basename(out), "frames", frames.length);
}

// A visible pointer. Clicks on `block` are shown (ring) but not performed;
// the edit cuts to the next scene instead of following the navigation.
export async function pointer(page, start = [1320, 640], { block = null } = {}) {
  await page.evaluate(({ start, block }) => {
    const c = document.createElement("div");
    c.id = "tz-cursor";
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", "28"); svg.setAttribute("height", "28");
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", "M3 2 L3 19 L7.5 15 L10.5 22 L13.5 20.7 L10.6 14 L17 14 Z");
    p.setAttribute("fill", "#111"); p.setAttribute("stroke", "#fff"); p.setAttribute("stroke-width", "1.6"); p.setAttribute("stroke-linejoin", "round");
    svg.appendChild(p); c.appendChild(svg);
    c.style.left = start[0] + "px"; c.style.top = start[1] + "px";
    document.body.appendChild(c);
    document.addEventListener("mousemove", (e) => { c.style.left = e.clientX + "px"; c.style.top = e.clientY + "px"; }, true);
    document.addEventListener("mousedown", (e) => {
      if (e.target.closest && e.target.closest("[contenteditable=true], input[type=text], input[type=search], textarea")) return;
      const r = document.createElement("div"); r.className = "tz-ring"; r.style.left = e.clientX + "px"; r.style.top = e.clientY + "px"; document.body.appendChild(r);
    }, true);
    if (block) document.addEventListener("click", (e) => { if (e.target.closest && e.target.closest(block)) { e.preventDefault(); e.stopPropagation(); } }, true);
  }, { start, block });
  let cx = start[0], cy = start[1];
  await page.mouse.move(cx, cy);
  const ez = (t) => (t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2);
  const glide = async (x, y, ms = 700) => {
    const n = Math.max(10, Math.round(ms / 16)), x0 = cx, y0 = cy;
    for (let i = 1; i <= n; i++) { const k = ez(i / n); await page.mouse.move(x0 + (x - x0) * k, y0 + (y - y0) * k); await page.waitForTimeout(16); }
    cx = x; cy = y;
  };
  const clickAt = async (x, y, ms) => { await glide(x, y, ms); await page.waitForTimeout(160); await page.mouse.down(); await page.waitForTimeout(80); await page.mouse.up(); };
  const centre = async (loc) => { const b = await loc.boundingBox(); return [b.x + b.width / 2, b.y + b.height / 2]; };
  const hide = () => page.evaluate(() => { const c = document.querySelector("#tz-cursor"); if (c) c.style.opacity = 0; });
  return { glide, clickAt, centre, hide, pos: () => [cx, cy] };
}
