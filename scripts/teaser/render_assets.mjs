// Renders the teaser's drawn assets with the local Chrome into _build/teaser/assets:
//   logo_white.png          the vutuv logo in white (from priv/static/images/vutuv-logo.svg)
//   badges/<network>.png    round network badges for the fediverse map
//   sites-<lang>/*.png      the three fictional websites behind Miriam's links
//
//   node scripts/teaser/render_assets.mjs <lang>
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const A = path.join(root, "_build/teaser/assets");
const lang = process.argv[2] || "de";
const c = JSON.parse(fs.readFileSync(path.join(here, `content.${lang}.json`), "utf8"));
const data = (file, type) => `data:${type};base64,` + fs.readFileSync(file).toString("base64");

const browser = await chromium.launch({ channel: "chrome" });
const page = await (await browser.newContext({ viewport: { width: 4000, height: 2000 } })).newPage();

// logo
const logo = data(path.join(root, "priv/static/images/vutuv-logo.svg"), "image/svg+xml");
await page.setContent(`<body style="margin:0;background:transparent"><img id="l" src="${logo}" style="width:3800px;filter:brightness(0) invert(1)"></body>`);
await page.waitForTimeout(300);
await page.locator("#l").screenshot({ path: path.join(A, "logo_white_full.png"), omitBackground: true });

// badges
const COLORS = { mastodon: "#6364FF", pixelfed: "#E0366D", misskey: "#86B300", peertube: "#F1680D", lemmy: "#00A67E" };
fs.mkdirSync(path.join(A, "badges"), { recursive: true });
await page.setViewportSize({ width: 400, height: 400 });
for (const name of [...Object.keys(COLORS), "friendica"]) {
  let svg = fs.readFileSync(path.join(A, "icons", `${name}.svg`), "utf8");
  svg = name === "friendica"
    ? svg.replace(/width="\d+" height="\d+"/, 'width="150" height="150"')
    : svg.replace("<svg", `<svg width="150" height="150" fill="${COLORS[name]}"`);
  await page.setContent(`<body style="margin:0;background:transparent"><div id="b" style="width:256px;height:256px;border-radius:50%;background:#fff;display:flex;align-items:center;justify-content:center;overflow:hidden">${svg}</div></body>`);
  await page.locator("#b").screenshot({ path: path.join(A, "badges", `${name}.png`), omitBackground: true });
}

// fictional websites
const avatar = data(path.join(A, "miriam_avatar.jpg"), "image/jpeg");
const cover = data(path.join(A, "raw_cover.jpg"), "image/jpeg");
const font = "font-family: -apple-system, 'Inter', 'Segoe UI', Helvetica, Arial, sans-serif;";
const s = c.sites;
const sites = {
  blog: `<body style="margin:0;${font};background:#0f172a;color:#e2e8f0">
    <div style="display:flex;justify-content:space-between;align-items:center;padding:28px 64px;border-bottom:1px solid #1e293b">
      <div style="display:flex;align-items:center;gap:16px"><img src="${avatar}" style="width:52px;height:52px;border-radius:50%"><b style="font-size:24px">Miriam Kessler</b></div>
      <div style="display:flex;gap:36px;font-size:19px;color:#94a3b8">${s.blog.nav.map((n) => `<span>${n}</span>`).join("")}</div></div>
    <div style="padding:70px 64px 0">
      <div style="color:#a78bfa;font-size:20px;font-weight:600">${s.blog.kicker}</div>
      <h1 style="font-size:64px;line-height:1.1;margin:18px 0 26px;color:#fff">${s.blog.title}</h1>
      <p style="font-size:24px;color:#94a3b8;max-width:900px;line-height:1.5">${s.blog.lead}</p></div>
    <div style="display:flex;gap:28px;padding:40px 64px">
      ${s.blog.cards.map(([d, t]) => `<div style="flex:1;background:#1e293b;border-radius:18px;padding:28px"><div style="color:#a78bfa;font-size:16px">${d}</div><div style="font-size:24px;font-weight:700;margin-top:10px;color:#f1f5f9">${t}</div></div>`).join("")}</div></body>`,
  stammtisch: `<body style="margin:0;${font};background:#fff;color:#1f2937">
    <div style="height:560px;background:url(${cover}) center 40%/cover;position:relative">
      <div style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(76,29,149,.15),rgba(76,29,149,.85))"></div>
      <div style="position:absolute;left:70px;bottom:60px;color:#fff">
        <div style="font-size:22px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;opacity:.9">${s.stammtisch.kicker}</div>
        <h1 style="font-size:78px;margin:10px 0 0;line-height:1">${s.stammtisch.title}</h1></div></div>
    <div style="display:flex;gap:30px;padding:44px 70px">
      ${s.stammtisch.facts.map(([k, v]) => `<div style="flex:1;border:2px solid #ede9fe;border-radius:18px;padding:26px"><div style="color:#7c3aed;font-weight:700;font-size:18px;text-transform:uppercase">${k}</div><div style="font-size:28px;font-weight:700;margin-top:8px">${v}</div></div>`).join("")}</div></body>`,
  lahnblick: `<body style="margin:0;${font};background:#f0fdf4;color:#14532d">
    <div style="display:flex;justify-content:space-between;align-items:center;padding:30px 70px;background:#fff">
      <div style="display:flex;align-items:center;gap:14px"><div style="width:46px;height:46px;border-radius:12px;background:linear-gradient(135deg,#16a34a,#0ea5e9)"></div><b style="font-size:28px;color:#14532d">Lahnblick Software</b></div>
      <div style="display:flex;gap:36px;font-size:20px;color:#166534">${s.lahnblick.nav.map((n, i, a) => i === a.length - 1 ? `<span style="background:#16a34a;color:#fff;padding:10px 22px;border-radius:999px">${n}</span>` : `<span>${n}</span>`).join("")}</div></div>
    <div style="display:flex;padding:80px 70px;gap:60px;align-items:center">
      <div style="flex:1.1"><h1 style="font-size:66px;line-height:1.08;margin:0 0 24px">${s.lahnblick.title}</h1>
        <p style="font-size:25px;color:#166534;line-height:1.5;margin:0">${s.lahnblick.lead}</p></div>
      <div style="flex:1;background:#fff;border-radius:22px;box-shadow:0 20px 50px rgba(20,83,45,.15);padding:28px">
        ${s.lahnblick.rows.map((t, i) => `<div style="display:flex;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid #dcfce7;font-size:21px"><span style="width:14px;height:14px;border-radius:50%;background:${["#16a34a", "#0ea5e9", "#f59e0b", "#16a34a"][i]}"></span>${t}</div>`).join("")}</div></div></body>`,
};
const siteDir = path.join(A, `sites-${lang}`);
fs.mkdirSync(siteDir, { recursive: true });
const sp = await (await browser.newContext({ viewport: { width: 1100, height: 726 }, deviceScaleFactor: 1.4545 })).newPage();
for (const [name, html] of Object.entries(sites)) {
  await sp.setContent(`<!doctype html><html><head><meta charset="utf-8"></head>${html}</html>`);
  await sp.waitForTimeout(300);
  await sp.screenshot({ path: path.join(siteDir, `${name}.png`) });
}
await browser.close();
console.log("rendered assets for", lang);
