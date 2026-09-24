// Records the portrait (phone) cut of the teaser: the same story as record.mjs,
// on a 9:16 phone screen (390x693 CSS pixels, recorded at 1080x1920), with a
// fingertip instead of a mouse pointer.
//
//   node scripts/teaser/record_portrait.mjs <lang> [scene ...]
//
// Scenes as in record.mjs; the phone differs where its navigation does:
//   feed    writing starts from the tab bar's "Write" button
//   post    the badges light up in the tab bar, and the envelope there is tapped
//   job     "Jobs" is reached through the footer, as on a phone
//   jobs    "Profile" is the avatar in the top bar
//   owner   the one-column profile scrolls from the header to the CV card
//   cv      the "Photo" switch sits below the download card
// Writes _build/teaser/<lang>/portrait/rec/<scene>/ and screens/, plus
// screens/card.json (the new post's box, for the fediverse shot) and
// screens/sheet.json (the printed sheet's box, for the save-as-PDF shot).
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { ROOT, BASE, CSS, HELPERS, PHONE, FRAME, launch, loadContent, newContext, open, dress, record, pointer,
  recordPhones, stammtischNeedles, HIDE_OTHER_STAMMTISCH, jobOrgs, HIDE_REAL_JOBS } from "./lib.mjs";

const [lang = "de", ...only] = process.argv.slice(2);
const BASE_OUT = path.join(ROOT, "_build/teaser", lang);
const OUT = path.join(BASE_OUT, "portrait");
const REC = path.join(OUT, "rec");
const SCREENS = path.join(OUT, "screens");
fs.mkdirSync(REC, { recursive: true });
fs.mkdirSync(SCREENS, { recursive: true });
const c = loadContent(lang);
const ids = JSON.parse(fs.readFileSync(path.join(BASE_OUT, "ids.json"), "utf8"));
const MIRIAM = path.join(BASE_OUT, "state-miriam.json");
const ANNA = path.join(BASE_OUT, "state-anna.json");
const POST = ids.post_id;
const SIZE = FRAME.phone;
const SCALE = PHONE.deviceScaleFactor; // CSS pixels -> frame pixels
const START = [300, 540]; // where the fingertip comes in
const wanted = (s) => only.length === 0 || only.includes(s);
const browser = await launch(chromium, PHONE);
const phone = (state) => newContext(browser, lang, state, PHONE);
const rec = (page, name, body) => record(page, path.join(REC, name), body, { size: SIZE });

// Scrolls `loc` into the band between the top bar and the tab bar before a tap.
async function reach(page, loc, at = 0.45) {
  const moved = await loc.evaluate((el, at) => {
    const r = el.getBoundingClientRect();
    if (r.top > 70 && r.bottom < innerHeight - 80) return false;
    window.tzScrollTo(0, Math.max(0, r.top + scrollY - innerHeight * at), 800);
    return true;
  }, at);
  if (moved) await page.waitForTimeout(950);
}

const needles = stammtischNeedles(c);

// ---------------------------------------------------------------- phones
if (wanted("phones")) await recordPhones(browser, lang, c, { miriam: MIRIAM, anna: ANNA, screens: SCREENS });

// ---------------------------------------------------------------- feed
if (wanted("feed")) {
  const ctx = await phone(MIRIAM);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/feed`, { waitUntil: "networkidle" });
  await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch (e) {} });
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForFunction(() => document.querySelector(".phx-connected"));
  await dress(page);
  await page.evaluate(HIDE_OTHER_STAMMTISCH, { post: POST, needles });
  await page.evaluate((POST) => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    window.tzHideCounts();
    const posts = $("#feed-posts");
    const mine = $$("#feed-posts > div").find((d) => d.querySelector(`[id*="${POST}"]`));
    mine.id = "tz-mine";
    const st = document.createElement("style");
    st.textContent = "#tz-mine .tabular-nums, #tz-mine [data-count] { visibility: hidden !important; }";
    document.head.appendChild(st);
    posts.prepend(mine);
    mine.style.display = "none";
    const block = mine.firstElementChild;
    if (block.children[1]) block.children[1].style.display = "none";
    $$("span.absolute", mine).forEach((s) => (s.style.opacity = 0));
    [$("#feed-filter-row"), ...$$("#feed-posts > div")].forEach((e) => e && e.classList.add("tz-h"));
    window.scrollTo(0, 0);
  }, POST);
  await page.waitForTimeout(1200);

  await rec(page, "feed", async () => {
    await page.evaluate(() => {
      const $ = (s) => document.querySelector(s), $$ = (s) => [...document.querySelectorAll(s)];
      tzAt(150, $("#feed-filter-row"), "tz-in");
      $$("#feed-posts > div").filter((d) => d.id !== "tz-mine").forEach((d, i) => tzAt(450 + i * 300, d, "tz-in"));
    });
    await page.waitForTimeout(1900);
    const p = await pointer(page, START, { block: '#composer-form button[type="submit"]', touch: true });
    const like = page.locator(`#remote-actions-post-${ids.news_top_id}-like`);
    await reach(page, like, 0.6);
    await p.clickAt(...(await p.centre(like)), 900);
    await page.waitForTimeout(800);
    await p.clickAt(...(await p.centre(page.locator(`#remote-actions-post-${ids.news_top_id}-repost`))), 700);
    await page.waitForTimeout(1100);
    // writing starts from the tab bar, where the thumb is
    await p.clickAt(...(await p.centre(page.locator("a[data-mobile-compose]"))), 800);
    await page.waitForSelector("#composer-form", { state: "visible" });
    await page.evaluate(() => { window.scrollTo(0, 0); const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form"); s.classList.remove("tz-in"); void s.offsetWidth; s.classList.add("tz-in"); });
    await page.waitForTimeout(800);
    const editor = page.locator("#composer-form [contenteditable=true]:visible").first();
    const eb = await editor.boundingBox();
    await p.clickAt(eb.x + 40, eb.y + 30, 500);
    await page.keyboard.type(c.post.line1, { delay: 32 });
    await page.keyboard.press("Enter");
    await page.keyboard.type(c.post.line2, { delay: 32 });
    await page.waitForTimeout(400);
    // select the second line with the finger, then B in the toolbar
    const sel = await editor.evaluate((e, line2) => {
      const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
      let tn; for (let n = w.nextNode(); n; n = w.nextNode()) if (n.nodeValue.includes(line2.slice(0, 8))) tn = n;
      const s = tn.nodeValue.indexOf(line2.slice(0, 8)), end = tn.nodeValue.length, rg = document.createRange();
      rg.setStart(tn, s); rg.setEnd(tn, s + 1); const a = rg.getClientRects()[0];
      rg.setStart(tn, end - 1); rg.setEnd(tn, end); const rs = rg.getClientRects(); const b = rs[rs.length - 1];
      return { ax: a.left + 1, ay: a.top + a.height / 2, bx: b.right, by: b.top + b.height / 2 };
    }, c.post.line2);
    await p.glide(sel.ax, sel.ay, 600);
    await page.waitForTimeout(200);
    await page.mouse.down();
    await p.glide(sel.bx, sel.by, 900);
    await page.mouse.up();
    await page.waitForTimeout(600);
    await p.clickAt(...(await p.centre(page.locator('button[data-mde-mark="strong"]:visible').first())), 600);
    await page.waitForTimeout(700);
    await p.clickAt(...(await p.centre(page.locator("#composer-tags-field"))), 700);
    for (const tag of c.post.tags) {
      await page.keyboard.type(tag, { delay: 55 });
      await page.keyboard.type(",", { delay: 55 });
      await page.waitForTimeout(250);
    }
    await page.waitForTimeout(500);
    const submit = page.locator('#composer-form button[type="submit"]:visible').last();
    await reach(page, submit, 0.55);
    await p.clickAt(...(await p.centre(submit)), 800);
    await page.waitForTimeout(350);
    await p.hide();
    await page.evaluate(() => { const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form"); s.classList.remove("tz-in"); s.classList.add("tz-out"); });
    await page.waitForTimeout(450);
    await page.evaluate(() => {
      const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form");
      s.style.display = "none";
      const gone = document.createElement("style");
      gone.textContent = "section:has(#composer-form) { display: none !important; }";
      document.head.appendChild(gone);
      window.scrollTo(0, 0);
      const mine = document.querySelector("#tz-mine");
      mine.style.display = ""; mine.classList.remove("tz-h"); mine.classList.add("tz-in");
    });
    await page.waitForTimeout(1600);
  });
  // where the new post sits in the last frame: the fediverse shot lifts it off from there
  const box = await page.evaluate(() => { const r = document.querySelector("#tz-mine").getBoundingClientRect(); return [r.left, r.top, r.right, Math.min(r.bottom, innerHeight - 70)]; });
  fs.writeFileSync(path.join(SCREENS, "card.json"), JSON.stringify(box.map((v) => Math.round(v * SCALE))));
  await ctx.close();
}

// ---------------------------------------------------------------- post
if (wanted("post")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, `/miriam_kessler/posts/${POST}`);
  await page.addStyleTag({ content: `#post-other-formats, footer { visibility: hidden !important; }
    #thread-focus.tz-noline::before { opacity: 0 !important; }
    nav[data-nav-bar="tabs"] .tz-badge { right: auto; left: calc(50% + 2px); }` });
  await page.evaluate((POST) => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    const focus = $("#thread-focus");
    const reply = focus.nextElementSibling;
    const textEl = $$("*", focus).find((e) => e.children.length === 0 && /^(Gefällt|Liked by)/.test(e.textContent.trim()));
    const avatars = $$("*", focus).filter((e) => /^[A-Z]{2}$/.test(e.textContent.trim()) && e.getBoundingClientRect().width > 20)
      .filter((e, i, all) => !all.some((o) => o !== e && o.contains(e)));
    const likeBtn = $(`[id$="${POST}-like"]`, focus);
    const likeCount = $$("span", likeBtn).find((s) => /^\d+$/.test(s.textContent.trim()) && !s.classList.contains("invisible"));
    const replyBtn = $(`[id$="${POST}-reply"]`, focus);
    const replyCount = replyBtn && $$("span", replyBtn).find((s) => /^\d+$/.test(s.textContent.trim()));
    window.tz = { focus, reply, textEl, avatars, likeCount, replyCount };
    avatars.forEach((a) => a.classList.add("tz-h"));
    if (textEl) textEl.classList.add("tz-h");
    if (likeCount) likeCount.textContent = "";
    if (replyCount) replyCount.textContent = "";
    if (reply) reply.classList.add("tz-h");
    const lines = $$("*", focus.parentElement).filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.width <= 3 && r.height > 30; });
    lines.forEach((l) => { l.style.transition = "opacity .5s"; l.style.opacity = 0; });
    window.tzLines = lines;
    if (parseFloat(getComputedStyle(focus, "::before").width) <= 3) focus.classList.add("tz-noline");
    // the badges belong on the tab bar, the only navigation a phone shows
    const mk = (sel) => { const a = $(`nav[data-nav-bar="tabs"] ${sel}`); if (!a) return null; const b = document.createElement("span"); b.className = "tz-badge"; a.style.position = "relative"; a.appendChild(b); return b; };
    window.tzBell = mk('a[href="/notifications"]');
    window.tzMail = mk('a[href="/messages"]');
  }, POST);
  await page.waitForTimeout(800);
  await rec(page, "post", async () => {
    await page.evaluate(() => {
      const { focus, reply, textEl, avatars, likeCount, replyCount } = window.tz;
      const beat = (e) => { if (!e) return; e.classList.remove("tz-beat"); void e.offsetWidth; e.classList.add("tz-beat"); };
      const badge = (b, n) => { if (!b) return; b.textContent = n; b.style.opacity = 1; b.classList.remove("tz-pop"); void b.offsetWidth; b.classList.add("tz-pop"); };
      const heart = likeCount && likeCount.parentElement.querySelector("svg");
      avatars.forEach((a, i) => setTimeout(() => { a.classList.add("tz-pop"); if (likeCount) { likeCount.textContent = String(i + 1); beat(likeCount); } beat(heart); badge(window.tzBell, i + 1); }, 400 + i * 900));
      setTimeout(() => textEl && textEl.classList.add("tz-in"), 400 + avatars.length * 900);
      setTimeout(() => {
        focus.classList.remove("tz-noline");
        (window.tzLines || []).forEach((l) => (l.style.opacity = 1));
        reply && reply.classList.add("tz-in");
        if (replyCount) { replyCount.textContent = "1"; beat(replyCount); }
        badge(window.tzBell, avatars.length + 1);
      }, 400 + avatars.length * 900 + 700);
      setTimeout(() => badge(window.tzMail, 1), 400 + avatars.length * 900 + 2600);
    });
    await page.waitForTimeout(6600);
    const p = await pointer(page, START, { block: 'a[href="/messages"]', touch: true });
    await p.clickAt(...(await p.centre(page.locator('nav[data-nav-bar="tabs"] a[href="/messages"]'))), 1000);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- chat
if (wanted("chat")) {
  const conv = ids.conversation_id;
  const miriamCtx = await phone(MIRIAM);
  // Anna types in a browser of her own, so her tab is in the foreground too
  const browser2 = await chromium.launch({ channel: "chrome" });
  const annaCtx = await newContext(browser2, lang, ANNA);
  const anna = await open(annaCtx, `/messages/${conv}`);
  const page = await open(miriamCtx, `/messages/${conv}`);
  await page.evaluate(() => {
    const root = document.querySelector("#messages");
    const cols = [...root.children].filter((c) => c.getBoundingClientRect().height > 0);
    const msgs = [...document.querySelectorAll('#message-thread > [id^="message-"]')];
    [...cols, ...msgs].forEach((e) => e.classList.add("tz-h"));
    document.querySelectorAll('[id$="-report"]').forEach((e) => (e.style.visibility = "hidden"));
    window.tzCh = { cols, msgs };
    new MutationObserver((ms) => ms.forEach((m) => m.addedNodes.forEach((n) => {
      if (n.nodeType === 1 && /^message-/.test(n.id || "") && !n.classList.contains("tz-seen")) { n.classList.add("tz-seen", "tz-in"); n.querySelectorAll('[id$="-report"]').forEach((e) => (e.style.visibility = "hidden")); }
    }))).observe(document.querySelector("#message-thread"), { childList: true });
  });
  await page.waitForTimeout(800);
  await anna.locator("#message-form button", { hasText: "Markdown" }).click();
  await anna.waitForTimeout(400);
  const ae = anna.locator("#message-body textarea:visible").first();
  const jobUrl = `${BASE}/jobs/${ids.main_job_slug}`;
  const paras = c.chat.anna.map((s) => s.replace("{job_title}", ids.main_job_title).replace("{job_url}", jobUrl));
  await rec(page, "chat", async () => {
    await page.evaluate(() => {
      const { cols, msgs } = window.tzCh;
      cols.forEach((c, i) => tzAt(150 + i * 250, c, "tz-in"));
      msgs.forEach((m, i) => tzAt(800 + i * 450, m, "tz-in"));
    });
    await page.waitForTimeout(1700);
    await ae.click();
    for (const [i, para] of paras.entries()) {
      if (i > 0) { await anna.keyboard.press("Shift+Enter"); await anna.keyboard.press("Shift+Enter"); }
      await anna.keyboard.type(para, { delay: 16 });
    }
    await anna.waitForTimeout(800);
    await anna.locator('#message-form button[type="submit"]').click();
    await page.waitForTimeout(4200);
    const p = await pointer(page, START, { block: 'a[href*="/jobs/"]', touch: true });
    const editor = page.locator("#message-body .ProseMirror");
    await reach(page, editor, 0.6);
    const eb = await editor.boundingBox();
    await p.clickAt(eb.x + 60, eb.y + eb.height / 2, 900);
    await page.keyboard.type(c.chat.miriam, { delay: 40 });
    await page.waitForTimeout(700);
    await p.clickAt(...(await p.centre(page.locator('#message-form button[type="submit"]'))), 700);
    await page.waitForTimeout(1600);
    const link = page.locator(`#message-thread a[href*="/jobs/${ids.main_job_slug}"]`).first();
    await link.evaluate((a) => a.scrollIntoView({ block: "center", behavior: "smooth" }));
    await page.waitForTimeout(700);
    const r = await link.evaluate((a) => { const q = a.getClientRects()[0]; return [q.left + q.width * 0.4, q.top + q.height / 2]; });
    await p.clickAt(r[0], r[1], 1000);
    await page.waitForTimeout(700);
  });
  await browser2.close();
  await miriamCtx.close();
}

const ORGS = jobOrgs(c);

// ---------------------------------------------------------------- job
if (wanted("job")) {
  const ctx = await phone(MIRIAM);
  const d = await open(ctx, `/jobs/${ids.main_job_slug}`);
  await d.addStyleTag({ content: "main aside, #job-other-formats { display: none !important; }" });
  await d.evaluate(() => {
    const main = document.querySelector("main");
    const cards = [...main.querySelectorAll("section")].filter((s) => !s.closest("aside") && s.getBoundingClientRect().height > 0);
    const first = cards[0];
    const md = cards[1].querySelector(".markdown") || cards[1];
    [...cards, ...first.children, ...first.querySelectorAll(".flex-wrap > span"), ...md.children, ...cards.slice(2).flatMap((c) => [...c.querySelectorAll("a")])]
      .forEach((p) => p.classList.add("tz-h"));
    window.tzD = { cards, first, md };
  });
  await d.waitForTimeout(800);
  await rec(d, "job", async () => {
    await d.evaluate(() => {
      const { cards, first, md } = window.tzD;
      tzAt(150, cards[0], "tz-in");
      [...first.children].forEach((c, i) => tzAt(450 + i * 250, c, "tz-in"));
      [...first.querySelectorAll(".flex-wrap > span")].forEach((c, i) => tzAt(800 + i * 140, c, "tz-pop"));
      tzAt(1900, cards[1], "tz-in");
      [...md.children].forEach((c, i) => tzAt(2100 + i * 220, c, "tz-in"));
      tzScrollTo(2300, tzTop(cards[1]) - 80, 1800);
      const last = cards[cards.length - 1];
      tzScrollTo(5000, Math.max(0, tzTop(last) + last.offsetHeight - window.innerHeight + 90), 1800);
      cards.slice(2).forEach((c) => tzAt(5200, c, "tz-in"));
      cards.slice(2).flatMap((c) => [...c.querySelectorAll("a")]).forEach((a, i) => tzAt(5600 + i * 180, a, "tz-pop"));
    });
    await d.waitForTimeout(7400);
    // a phone keeps "Jobs" in the footer
    const p = await pointer(d, START, { block: 'a[href="/jobs"]', touch: true });
    const jobs = d.locator('footer a[href="/jobs"]').first();
    await reach(d, jobs, 0.5);
    await p.clickAt(...(await p.centre(jobs)), 1000);
    await d.waitForTimeout(800);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- jobs
if (wanted("jobs")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, "/jobs");
  await page.evaluate(HIDE_REAL_JOBS, ORGS);
  await page.evaluate(() => {
    const main = document.querySelector("main");
    const head = main.querySelector("div.py-6 > div"), form = main.querySelector("form");
    const chips = document.querySelector("#job-filter-chips");
    const tags = [...document.querySelectorAll("#job-tag-filters > *")].filter((t) => t.style.display !== "none");
    const cards = [...main.querySelectorAll("article")].filter((a) => a.style.display !== "none");
    [head, form, chips, ...tags, ...cards].forEach((p) => p && p.classList.add("tz-h"));
    window.tzE = { head, form, chips, tags, cards };
  });
  await page.waitForTimeout(800);
  await rec(page, "jobs", async () => {
    await page.evaluate(() => {
      const { head, form, chips, tags, cards } = window.tzE;
      tzAt(150, head, "tz-in"); tzAt(450, form, "tz-in"); tzAt(750, chips, "tz-in");
      tags.forEach((t, i) => tzAt(950 + i * 80, t, "tz-pop"));
      cards.forEach((c, i) => tzAt(1300 + i * 300, c, "tz-in"));
    });
    await page.waitForTimeout(1500);
    const p = await pointer(page, START, { touch: true });
    const q = page.locator('main input[name="q"]');
    await reach(page, q, 0.35);
    await p.clickAt(...(await p.centre(q)), 900);
    await page.keyboard.type(c.search.q, { delay: 90 });
    await page.waitForTimeout(300);
    await p.clickAt(...(await p.centre(page.locator('main input[name="near"]'))), 700);
    await page.keyboard.type(c.search.near, { delay: 90 });
    await page.waitForTimeout(300);
    const radius = page.locator('main select[name="radius"]');
    await p.clickAt(...(await p.centre(radius)), 700);
    await radius.selectOption(c.search.radius);
    await page.waitForTimeout(600);
    const submit = page.locator('main form button[type="submit"]').first();
    await reach(page, submit, 0.55);
    const [x, y] = p.pos();
    await p.clickAt(...(await p.centre(submit)), 700);
    await page.waitForURL(/[?&]q=/i, { timeout: 15000 });
    await page.waitForLoadState("domcontentloaded");
    await page.waitForTimeout(150);
    await page.addStyleTag({ content: CSS });
    await page.evaluate(HELPERS);
    await page.evaluate(HIDE_REAL_JOBS, ORGS);
    await page.waitForLoadState("networkidle");
    await page.evaluate(() => {
      window.tzHideCounts();
      const cards = [...document.querySelectorAll("main article")].filter((a) => a.style.display !== "none");
      window.scrollTo(0, 0);
      if (cards[0]) tzScrollTo(300, tzTop(cards[0]) - 90, 1300);
      if (cards[2]) tzScrollTo(2300, tzTop(cards[2]) - 90, 1300);
    });
    await page.waitForTimeout(4200);
    await page.evaluate(() => tzScrollTo(0, 0, 900));
    await page.waitForTimeout(1000);
    // on a phone the profile sits behind the avatar in the top bar: its menu,
    // then "View profile"
    const p2 = await pointer(page, [x, y], { block: 'a[href="/miriam_kessler"]', touch: true });
    const avatar = await page.evaluate(() => {
      const r = document.elementFromPoint(innerWidth - 32, 32).getBoundingClientRect();
      return [r.left + r.width / 2, r.top + r.height / 2];
    });
    await p2.clickAt(...avatar, 1100);
    await page.waitForTimeout(700);
    await p2.clickAt(...(await p2.centre(page.locator('a[href="/miriam_kessler"]:visible').filter({ hasText: /Miriam Kessler/ }).last())), 700);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- owner
if (wanted("owner")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, "/miriam_kessler");
  await page.addStyleTag({ content: `
    #profile-job-references, #profile-qualifications, #profile-press, #profile-about, #profile-messengers,
    #profile-addresses, #profile-who-to-follow, #profile-other-formats, #profile-following, #profile-followers,
    #profile-posts div:has(> #composer-panel),
    main [class*=border-dashed] { display: none !important; }` });
  await page.evaluate(() => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    window.scrollTo(0, 0);
    const secs = $$("main section").filter((s) => getComputedStyle(s).display !== "none" && s.getBoundingClientRect().height > 0 && !s.closest("#profile-cv-card"));
    const header = secs[0];
    const cover = header.children[0], body = header.children[1];
    const rest = secs.slice(1);
    // what pops inside a card once it is on screen
    const inner = (s) => [...s.querySelectorAll(".flex-wrap > div, .flex-wrap > a, div.grid > div, .divide-y > div > *, article")]
      .filter((e) => e.getBoundingClientRect().height > 0);
    [header, cover, ...body.children, ...rest, ...rest.flatMap(inner)].forEach((p) => p.classList.add("tz-h"));
    const seen = new WeakSet();
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (!e.isIntersecting || seen.has(e.target)) return;
      seen.add(e.target);
      e.target.classList.add("tz-in");
      inner(e.target).forEach((el, i) => tzAt(250 + i * 110, el, "tz-pop"));
    }), { threshold: 0.12 });
    window.tzO = { header, cover, body, rest, io };
    const titled = (t) => secs.find((s) => s.querySelector("h2")?.textContent.trim() === t);
    window.tzStops = [titled("Tags"), $("#profile-experience"), $("#profile-links"), $("#profile-code-stats"), $("#profile-social-posts")].filter(Boolean);
  });
  await page.waitForTimeout(800);
  await rec(page, "owner", async () => {
    await page.evaluate(() => {
      const { header, cover, body, rest, io } = window.tzO;
      tzAt(150, header, "tz-in");
      tzAt(450, cover, "tz-cover");
      const [avatarRow, nameRow, ...more] = body.children;
      tzAt(1100, avatarRow, "tz-pop");
      tzAt(1500, nameRow, "tz-in");
      more.forEach((el, i) => tzAt(1800 + i * 200, el, "tz-in"));
      setTimeout(() => rest.forEach((s) => io.observe(s)), 2400);
      let t = 3000;
      for (const s of window.tzStops) {
        tzScrollTo(t, tzTop(s) - 80, 1100);
        t += 1100 + (s.id === "profile-experience" ? 2300 : 1400);
      }
      window.tzEnd = t;
    });
    const end = await page.evaluate(() => window.tzEnd);
    await page.waitForTimeout(end);
    await page.evaluate(() => { const c = document.querySelector("#profile-cv-card"); c.classList.remove("tz-h"); c.style.opacity = 1; tzScrollTo(0, tzTop(c) - 160, 1300); });
    await page.waitForTimeout(1500);
    const p = await pointer(page, START, { block: "#profile-cv-card a", touch: true });
    await p.clickAt(...(await p.centre(page.locator("#profile-cv-card a").last())), 1000);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- cv
if (wanted("cv")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, "/miriam_kessler/cv");
  await page.evaluate(() => {
    const main = document.querySelector("main");
    const head = main.querySelector("div.py-6 > div");
    const cards = [...main.querySelectorAll("section")].filter((s) => s.getBoundingClientRect().height > 0);
    [head, ...cards].forEach((p) => p && p.classList.add("tz-h"));
    window.tzB = { head, cards };
  });
  await page.waitForTimeout(800);
  await rec(page, "cv", async () => {
    await page.evaluate(() => {
      const { head, cards } = window.tzB;
      tzAt(150, head, "tz-in");
      cards.forEach((c, i) => tzAt(400 + i * 220, c, "tz-in"));
    });
    await page.waitForTimeout(2200);
    const p = await pointer(page, START, { block: "#cv-print", touch: true });
    const photo = page.locator('input[phx-value-key="photo"]');
    await reach(page, photo, 0.45);
    await p.clickAt(...(await p.centre(photo)), 1000);
    await page.waitForTimeout(1300);
    const print = page.locator("#cv-print");
    await reach(page, print, 0.4);
    await p.clickAt(...(await p.centre(print)), 1000);
    await page.waitForTimeout(800);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- print + sheet
if (wanted("print") || wanted("sheet")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, "/miriam_kessler/cv/print?hide=photo", { live: false });
  await page.addStyleTag({ content: ".noprint { display: none !important; } body { background: #f0f3f9 !important; }" });
  if (wanted("sheet")) {
    await page.waitForTimeout(400);
    await page.locator(".sheet").screenshot({ path: path.join(SCREENS, "cv_sheet.png") });
    const box = await page.evaluate(() => { const r = document.querySelector(".sheet").getBoundingClientRect(); return [r.left, r.width]; });
    fs.writeFileSync(path.join(SCREENS, "sheet.json"), JSON.stringify(box.map((v) => Math.round(v * SCALE))));
    console.log("sheet done");
  }
  if (wanted("print")) {
    await page.evaluate(() => {
      const sheet = document.querySelector(".sheet");
      [sheet, ...sheet.querySelectorAll("header .head > div > *, header > div > *, section > h2, article, p.items")].forEach((p) => p.classList.add("tz-h"));
      window.tzC = { sheet };
    });
    await page.waitForTimeout(600);
    await rec(page, "print", async () => {
      await page.evaluate(() => {
        const { sheet } = window.tzC;
        tzAt(100, sheet, "tz-in");
        [...sheet.querySelectorAll(".tz-h")].filter((el) => el.getBoundingClientRect().top < innerHeight).forEach((el, i) => tzAt(450 + i * 170, el, "tz-in"));
        [...sheet.querySelectorAll(".tz-h")].filter((el) => el.getBoundingClientRect().top >= innerHeight).forEach((el) => el.classList.add("tz-in"));
      });
      await page.waitForTimeout(4200);
    });
  }
  await ctx.close();
}

await browser.close();
