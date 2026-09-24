// Records every scene of the teaser from the running teaser server.
//
//   node scripts/teaser/record.mjs <lang> [scene ...]
//
// Scenes (see README.md for the storyboard):
//   phones  three phone screenshots for the opening
//   feed    Miriam likes + reposts the news, writes her post, bolds a line, tags, posts
//   post    her post page: likes pop in, Anna replies, a DM badge lights up
//   chat    Anna's DM arrives live (with typing indicator), Miriam answers, opens the link
//   job     the job posting builds itself, then Miriam goes to the job board
//   jobs    the job board: search "Elixir" + city + radius, then to her profile
//   owner   her own profile builds itself, then "open CV"
//   cv      CV page: untick "Photo", click "Print / Save as PDF"
//   print   the print view (without photo) builds itself
//   sheet   a full screenshot of the printed CV sheet (for the save-as-PDF animation)
// Without scene names it records all of them, in this order. Needs
// _build/teaser/<lang>/ids.json (seed.exs) and state-*.json (login.mjs).
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { ROOT, BASE, CSS, HELPERS, DESKTOP, launch, loadContent, newContext, open, dress, record, pointer,
  recordPhones, stammtischNeedles, HIDE_OTHER_STAMMTISCH, jobOrgs, HIDE_REAL_JOBS } from "./lib.mjs";

const [lang = "de", ...only] = process.argv.slice(2);
const OUT = path.join(ROOT, "_build/teaser", lang);
const REC = path.join(OUT, "rec");
const SCREENS = path.join(OUT, "screens");
fs.mkdirSync(REC, { recursive: true });
fs.mkdirSync(SCREENS, { recursive: true });
const c = loadContent(lang);
const ids = JSON.parse(fs.readFileSync(path.join(OUT, "ids.json"), "utf8"));
const MIRIAM = path.join(OUT, "state-miriam.json");
const ANNA = path.join(OUT, "state-anna.json");
const POST = ids.post_id;
const wanted = (s) => only.length === 0 || only.includes(s);
const browser = await launch(chromium, DESKTOP);
const needles = stammtischNeedles(c);

// ---------------------------------------------------------------- phones
if (wanted("phones")) await recordPhones(browser, lang, c, { miriam: MIRIAM, anna: ANNA, screens: SCREENS });

// ---------------------------------------------------------------- feed
if (wanted("feed")) {
  const ctx = await newContext(browser, lang, MIRIAM);
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
    // Miriam's post (with Anna's reply) is held back and lands on top after "Post"
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
    [$("#composer-trigger"), $("main section"), ...$$("#feed-posts > div"), $("#feed-calendar-rail"), $("#feed-filter-row"), $("#rail-followed_tags"), $("#feed-other-formats")]
      .forEach((e) => e && e.classList.add("tz-h"));
    window.scrollTo(0, 0);
  }, POST);
  await page.waitForTimeout(1200);

  await record(page, path.join(REC, "feed"), async () => {
    await page.evaluate(() => {
      const $ = (s) => document.querySelector(s), $$ = (s) => [...document.querySelectorAll(s)];
      tzAt(200, $("#composer-trigger"), "tz-in");
      tzAt(500, $("main section"), "tz-in");
      $$("#feed-posts > div").filter((d) => d.id !== "tz-mine").forEach((d, i) => tzAt(900 + i * 350, d, "tz-in"));
      tzAt(700, $("#feed-calendar-rail"), "tz-in");
      tzAt(1000, $("#feed-filter-row"), "tz-in");
      tzAt(1300, $("#rail-followed_tags"), "tz-in");
      tzAt(2000, $("#feed-other-formats"), "tz-in");
    });
    await page.waitForTimeout(3200);
    // the post already exists; the "Post" click only plays the fold-away
    const p = await pointer(page, [1320, 600], { block: '#composer-form button[type="submit"]' });
    await p.clickAt(...(await p.centre(page.locator(`#remote-actions-post-${ids.news_top_id}-like`))), 1100);
    await page.waitForTimeout(900);
    await p.clickAt(...(await p.centre(page.locator(`#remote-actions-post-${ids.news_top_id}-repost`))), 800);
    await page.waitForTimeout(1300);
    await p.clickAt(...(await p.centre(page.locator("#open-composer"))), 900);
    await page.waitForSelector("#composer-form", { state: "visible" });
    await page.evaluate(() => { const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form"); s.classList.remove("tz-in"); void s.offsetWidth; s.classList.add("tz-in"); });
    await page.waitForTimeout(800);
    const editor = page.locator("#composer-form [contenteditable=true]:visible").first();
    const eb = await editor.boundingBox();
    await p.clickAt(eb.x + 40, eb.y + 30, 500);
    await page.keyboard.type(c.post.line1, { delay: 32 });
    await page.keyboard.press("Enter");
    await page.keyboard.type(c.post.line2, { delay: 32 });
    await page.waitForTimeout(400);
    // select the second line with the mouse, then B in the toolbar
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
    await p.clickAt(...(await p.centre(page.locator('#composer-form button[type="submit"]:visible').last())), 800);
    await page.waitForTimeout(350);
    await p.hide();
    await page.evaluate(() => { const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form"); s.classList.remove("tz-in"); s.classList.add("tz-out"); });
    await page.waitForTimeout(450);
    await page.evaluate(() => {
      const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form");
      s.style.display = "none";
      // a LiveView patch re-shows the composer; a rule in <head> survives it
      const gone = document.createElement("style");
      gone.textContent = "section:has(#composer-form) { display: none !important; }";
      document.head.appendChild(gone);
      document.querySelector("#composer-trigger").style.display = "";
      const mine = document.querySelector("#tz-mine");
      mine.style.display = ""; mine.classList.remove("tz-h"); mine.classList.add("tz-in");
    });
    await page.waitForTimeout(1600);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- post
if (wanted("post")) {
  const ctx = await newContext(browser, lang, MIRIAM);
  const page = await open(ctx, `/miriam_kessler/posts/${POST}`);
  await page.addStyleTag({ content: `#post-other-formats, footer { visibility: hidden !important; }
    #thread-focus.tz-noline::before { opacity: 0 !important; }` });
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
    const mk = (sel) => { const a = $(sel); if (!a) return null; const b = document.createElement("span"); b.className = "tz-badge"; a.style.position = "relative"; a.appendChild(b); return b; };
    window.tzBell = mk('a[href="/notifications"]');
    window.tzMail = mk('a[href="/messages"]');
  }, POST);
  await page.waitForTimeout(800);
  await record(page, path.join(REC, "post"), async () => {
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
    const p = await pointer(page, [1320, 700], { block: 'a[href="/messages"]' });
    await p.clickAt(...(await p.centre(page.locator('header a[href="/messages"], nav a[href="/messages"]').first())), 1100);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- chat
if (wanted("chat")) {
  const conv = ids.conversation_id;
  const miriamCtx = await newContext(browser, lang, MIRIAM);
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
  // Anna writes Markdown, so the job link is a real link
  await anna.locator("#message-form button", { hasText: "Markdown" }).click();
  await anna.waitForTimeout(400);
  const ae = anna.locator("#message-body textarea:visible").first();
  const jobUrl = `${BASE}/jobs/${ids.main_job_slug}`;
  const paras = c.chat.anna.map((s) => s.replace("{job_title}", ids.main_job_title).replace("{job_url}", jobUrl));
  await record(page, path.join(REC, "chat"), async () => {
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
    const p = await pointer(page, [1320, 700], { block: 'a[href*="/jobs/"]' });
    const editor = page.locator("#message-body .ProseMirror");
    const eb = await editor.boundingBox();
    await p.clickAt(eb.x + 60, eb.y + eb.height / 2, 900);
    await page.keyboard.type(c.chat.miriam, { delay: 40 });
    await page.waitForTimeout(700);
    await p.clickAt(...(await p.centre(page.locator('#message-form button[type="submit"]'))), 700);
    await page.waitForTimeout(1600);
    const link = page.locator(`#message-thread a[href*="/jobs/${ids.main_job_slug}"]`).first();
    await link.evaluate((a) => a.scrollIntoView({ block: "center", behavior: "smooth" }));
    await page.waitForTimeout(600);
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
  const ctx = await newContext(browser, lang, MIRIAM);
  const d = await open(ctx, `/jobs/${ids.main_job_slug}`);
  await d.addStyleTag({ content: "main aside { visibility: hidden !important; }" });
  await d.evaluate(() => {
    const main = document.querySelector("main");
    const cards = [...main.querySelectorAll("section")].filter((s) => !s.closest("aside"));
    const first = cards[0];
    const md = cards[1].querySelector(".markdown") || cards[1];
    [...cards, ...first.children, ...first.querySelectorAll(".flex-wrap > span"), ...md.children, ...cards.slice(2).flatMap((c) => [...c.querySelectorAll("a")])]
      .forEach((p) => p.classList.add("tz-h"));
    window.tzD = { cards, first, md };
  });
  await d.waitForTimeout(800);
  await record(d, path.join(REC, "job"), async () => {
    await d.evaluate(() => {
      const { cards, first, md } = window.tzD;
      tzAt(150, cards[0], "tz-in");
      [...first.children].forEach((c, i) => tzAt(450 + i * 280, c, "tz-in"));
      [...first.querySelectorAll(".flex-wrap > span")].forEach((c, i) => tzAt(800 + i * 140, c, "tz-pop"));
      tzAt(1900, cards[1], "tz-in");
      [...md.children].forEach((c, i) => tzAt(2100 + i * 260, c, "tz-in"));
      tzScrollTo(2300, tzTop(cards[1]) - 80, 1800);
      tzScrollTo(5400, Math.max(0, tzTop(cards[2]) + cards[2].offsetHeight - window.innerHeight + 40), 1500);
      tzAt(5500, cards[2], "tz-in");
      [...cards[2].querySelectorAll("a")].forEach((a, i) => tzAt(5900 + i * 180, a, "tz-pop"));
    });
    await d.waitForTimeout(7400);
    await d.evaluate(() => tzScrollTo(0, 0, 1300));
    await d.waitForTimeout(1500);
    const p = await pointer(d, [1320, 700], { block: 'a[href="/jobs"]' });
    await p.clickAt(...(await p.centre(d.locator('header a[href="/jobs"], nav a[href="/jobs"]').first())), 1100);
    await d.waitForTimeout(800);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- jobs
if (wanted("jobs")) {
  const ctx = await newContext(browser, lang, MIRIAM);
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
  await record(page, path.join(REC, "jobs"), async () => {
    await page.evaluate(() => {
      const { head, form, chips, tags, cards } = window.tzE;
      tzAt(150, head, "tz-in"); tzAt(450, form, "tz-in"); tzAt(750, chips, "tz-in");
      tags.forEach((t, i) => tzAt(950 + i * 80, t, "tz-pop"));
      cards.forEach((c, i) => tzAt(1300 + i * 300, c, "tz-in"));
    });
    await page.waitForTimeout(1500);
    const p = await pointer(page, [1320, 700], {});
    await p.clickAt(...(await p.centre(page.locator('main input[name="q"]'))), 1000);
    await page.keyboard.type(c.search.q, { delay: 90 });
    await page.waitForTimeout(300);
    await p.clickAt(...(await p.centre(page.locator('main input[name="near"]'))), 700);
    await page.keyboard.type(c.search.near, { delay: 90 });
    await page.waitForTimeout(300);
    const radius = page.locator('main select[name="radius"]');
    await p.clickAt(...(await p.centre(radius)), 700);
    await radius.selectOption(c.search.radius);
    await page.waitForTimeout(600);
    const [x, y] = p.pos();
    await p.clickAt(...(await p.centre(page.locator('main form button[type="submit"]').first())), 700);
    // the search is a real GET: dress the result page before it paints for long
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
      if (cards[0]) tzScrollTo(300, tzTop(cards[0]) - 240, 1200);
    });
    await page.waitForTimeout(2600);
    await page.evaluate(() => tzScrollTo(0, 0, 900));
    await page.waitForTimeout(1000);
    const p2 = await pointer(page, [x, y], { block: "header a, nav a" });
    const prof = page.locator('header a[href="/miriam_kessler"]').filter({ hasText: /^\s*(Profil|Profile)\s*$/ }).first();
    await p2.clickAt(...(await p2.centre(prof)), 1100);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- owner
if (wanted("owner")) {
  const ctx = await newContext(browser, lang, MIRIAM);
  const page = await open(ctx, "/miriam_kessler");
  // the owner view's empty "add ..." cards would read as unfinished in the film
  await page.addStyleTag({ content: `
    #profile-job-references, #profile-qualifications, #profile-press, #profile-about, #profile-messengers,
    #profile-addresses, #profile-who-to-follow, #profile-other-formats, #profile-following, #profile-followers,
    #profile-posts div:has(> #composer-panel),
    main [class*=border-dashed] { display: none !important; }` });
  await page.evaluate(() => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    window.scrollTo(0, 0);
    const secs = $$("main section").filter((s) => getComputedStyle(s).display !== "none" && s.getBoundingClientRect().height > 0);
    const header = secs[0];
    const cover = header.children[0], body = header.children[1];
    const tags = secs.find((s) => s.querySelector("h2")?.textContent.trim() === "Tags");
    const exp = $("#profile-experience"), edu = $("#profile-education"), lang = $("#profile-languages"), links = $("#profile-links");
    const code = $("#profile-code-stats"), sposts = $("#profile-social-posts");
    const group = exp.querySelector("div.relative.ml-5");
    const subs = group ? [...group.children].filter((c) => c.tagName === "DIV") : [];
    const bubbles = $$(".rounded-full", exp).filter((b) => b.offsetWidth > 25);
    const linkCards = links ? [...links.querySelectorAll("div.grid > div")] : [];
    const repoRows = code ? [...code.querySelectorAll(".divide-y > div > *")] : [];
    const postRows = sposts ? [...sposts.querySelectorAll("article, li")] : [];
    [...secs, cover, ...body.children, ...$$(".flex-wrap > div", tags), ...subs, ...bubbles, ...linkCards, ...repoRows, ...postRows, ...$$(".flex-wrap > *", lang)]
      .forEach((p) => p.classList.add("tz-h"));
    window.tzO = { secs, header, cover, body, tags, exp, edu, lang, links, subs, bubbles, linkCards, repoRows, postRows };
  });
  await page.waitForTimeout(800);
  await record(page, path.join(REC, "owner"), async () => {
    await page.evaluate(() => {
      const { secs, header, cover, body, tags, exp, edu, lang, links, subs, bubbles, linkCards, repoRows, postRows } = window.tzO;
      tzAt(150, header, "tz-in");
      tzAt(450, cover, "tz-cover");
      const [avatarRow, nameRow, ...rest] = body.children;
      tzAt(1100, avatarRow, "tz-pop");
      tzAt(1500, nameRow, "tz-in");
      rest.forEach((el, i) => tzAt(1800 + i * 200, el, "tz-in"));
      secs.filter((s) => s.getBoundingClientRect().left > 800).forEach((s, i) => tzAt(800 + i * 350, s, "tz-in"));
      repoRows.forEach((r, i) => tzAt(1900 + i * 150, r, "tz-in"));
      postRows.forEach((r, i) => tzAt(2600 + i * 300, r, "tz-in"));
      secs.filter((s) => s !== header && s.getBoundingClientRect().left < 800 && ![exp, links, tags, edu, lang].includes(s)).forEach((s) => tzAt(2300, s, "tz-in"));
      tzAt(2600, tags, "tz-in");
      [...tags.querySelectorAll(".flex-wrap > div")].forEach((el, i) => tzAt(2900 + i * 110, el, "tz-pop"));
      tzScrollTo(3700, tzTop(tags) - 90, 1500);
      tzScrollTo(5500, tzTop(exp) - 70, 1400);
      tzAt(5600, exp, "tz-in");
      bubbles.forEach((b, i) => tzAt(6100 + i * 1400, b, "tz-pop"));
      subs.forEach((s, i) => tzAt(6200 + i * 320, s, "tz-in"));
      tzScrollTo(8300, tzTop(edu) - 70, 1200);
      tzAt(8300, edu, "tz-in");
      tzAt(8700, lang, "tz-in");
      [...lang.querySelectorAll(".flex-wrap > *")].forEach((el, i) => tzAt(9000 + i * 150, el, "tz-pop"));
      if (links) {
        tzScrollTo(10000, tzTop(links) - 70, 1400);
        tzAt(10000, links, "tz-in");
        linkCards.forEach((c, i) => tzAt(10600 + i * 350, c, "tz-pop"));
      }
    });
    await page.waitForTimeout(13000);
    await page.evaluate(() => { const c = document.querySelector("#profile-cv-card"); c.classList.remove("tz-h"); c.style.opacity = 1; tzScrollTo(0, tzTop(c) - 200, 1200); });
    await page.waitForTimeout(1500);
    const p = await pointer(page, [700, 650], { block: "#profile-cv-card a" });
    await p.clickAt(...(await p.centre(page.locator("#profile-cv-card a").last())), 1000);
    await page.waitForTimeout(700);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- cv
if (wanted("cv")) {
  const ctx = await newContext(browser, lang, MIRIAM);
  const page = await open(ctx, "/miriam_kessler/cv");
  await page.evaluate(() => {
    const main = document.querySelector("main");
    const head = main.querySelector("div.py-6 > div");
    const cards = [...main.querySelectorAll("section")];
    [head, ...cards].forEach((p) => p.classList.add("tz-h"));
    window.tzB = { head, cards };
  });
  await page.waitForTimeout(800);
  await record(page, path.join(REC, "cv"), async () => {
    await page.evaluate(() => {
      const { head, cards } = window.tzB;
      tzAt(150, head, "tz-in");
      cards.filter((c) => !c.closest("aside")).forEach((c, i) => tzAt(400 + i * 220, c, "tz-in"));
      cards.filter((c) => c.closest("aside")).forEach((c, i) => tzAt(700 + i * 220, c, "tz-in"));
    });
    await page.waitForTimeout(2600);
    const p = await pointer(page, [1320, 700], { block: "#cv-print" });
    await p.clickAt(...(await p.centre(page.locator('input[phx-value-key="photo"]'))), 1100);
    await page.waitForTimeout(1300);
    await p.clickAt(...(await p.centre(page.locator("#cv-print"))), 1000);
    await page.waitForTimeout(800);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- print + sheet
if (wanted("print") || wanted("sheet")) {
  const ctx = await newContext(browser, lang, MIRIAM);
  const page = await open(ctx, "/miriam_kessler/cv/print?hide=photo", { live: false });
  await page.addStyleTag({ content: ".noprint { display: none !important; } body { background: #f0f3f9 !important; }" });
  if (wanted("sheet")) {
    await page.waitForTimeout(400);
    await page.locator(".sheet").screenshot({ path: path.join(SCREENS, "cv_sheet.png") });
    console.log("sheet done");
  }
  if (wanted("print")) {
    await page.evaluate(() => {
      const sheet = document.querySelector(".sheet");
      [sheet, ...sheet.querySelectorAll("header .head > div > *, header > div > *, section > h2, article, p.items")].forEach((p) => p.classList.add("tz-h"));
      window.tzC = { sheet };
    });
    await page.waitForTimeout(600);
    await record(page, path.join(REC, "print"), async () => {
      await page.evaluate(() => {
        const { sheet } = window.tzC;
        tzAt(100, sheet, "tz-in");
        [...sheet.querySelectorAll(".tz-h")].forEach((el, i) => tzAt(450 + i * 170, el, "tz-in"));
      });
      await page.waitForTimeout(5200);
    });
  }
  await ctx.close();
}

await browser.close();
