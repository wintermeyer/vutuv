// Records the portrait (phone) cut of the teaser: the same scenes as record.mjs,
// on a 9:16 phone screen (390x693 CSS pixels, recorded at 1080x1920), with a
// fingertip instead of a mouse pointer.
//
//   node scripts/teaser/record_portrait.mjs <lang> [scene ...]
//
// Scenes (see README.md):
//   profile    Miriam's profile as Anna sees it: it builds itself, Anna gives a
//              tag her vote, then on down through the CV, links and book reviews
//   feed       Miriam likes + reposts the news, writes her post from the tab
//              bar's "Write" button, bolds a line, tags, posts
//   post       her post page: likes pop in, Anna replies, then ⋯ > "Reach analysis"
//   reach      the reach analysis of an older post: its repost reach bars grow
//   jobs       the job board: "Elixir" in her city, the list swaps to the jobs there
//   outro      the three phone shots for the end, taken in this format's run
// Writes _build/teaser/<lang>/portrait/rec/<scene>/, plus screens/card.json
// (the new post's box, for the fediverse shot) and the outro's screens/o_*.png.
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { ROOT, BASE, CSS, HELPERS, PHONE, FRAME, launch, loadContent, newContext, open, dress, record, pointer,
  stammtischNeedles, HIDE_OTHER_STAMMTISCH, jobOrgs, HIDE_REAL_JOBS, hideReachPost, recordOutro } from "./lib.mjs";

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
const rec = (page, name, body) => record(page, path.join(REC, name), body, { size: SIZE });  // body gets mark(name)
const needles = stammtischNeedles(c);
const ORGS = jobOrgs(c);

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

// ---------------------------------------------------------------- outro phones
// First, before the scenes change what they show; this format's own take, so
// the post in the shots carries this take's time of day.
if (wanted("outro")) await recordOutro(browser, lang, c, ids, { miriam: MIRIAM, anna: ANNA, screens: SCREENS });

// ---------------------------------------------------------------- profile
if (wanted("profile")) {
  // Anna visits: a visitor's tag counts are buttons, and she gives one a vote
  const ctx = await phone(ANNA);
  const page = await open(ctx, "/miriam_kessler");
  await hideReachPost(page, ids);
  await page.addStyleTag({ content: `
    #profile-job-references, #profile-qualifications, #profile-press, #profile-about, #profile-messengers,
    #profile-addresses, #profile-who-to-follow, #profile-other-formats, #profile-following, #profile-followers,
    #profile-education, #profile-languages, #profile-code-stats, #profile-social-posts, #profile-cv-card,
    #profile-posts div:has(> #composer-panel),
    main [class*=border-dashed] { display: none !important; }` });
  await page.evaluate(() => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    window.scrollTo(0, 0);
    const secs = $$("main section").filter((s) => getComputedStyle(s).display !== "none" && s.getBoundingClientRect().height > 0);
    const header = secs[0];
    const cover = header.children[0], body = header.children[1];
    const rest = secs.slice(1);
    // what pops inside a card once it is on screen
    const inner = (s) => [...s.querySelectorAll(".flex-wrap > div, div.grid > div, article, li, div.relative.ml-5 > div")]
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
    window.tzTags = titled("Tags");
    // after the vote: the CV, then her links and book reviews, in page order
    window.tzStops = [$("#profile-experience"), $("#profile-links"), $("#profile-book-reviews")].filter(Boolean)
      .sort((a, b) => tzTop(a) - tzTop(b));
  });
  await page.waitForTimeout(800);
  await rec(page, "profile", async () => {
    await page.evaluate(() => {
      const { header, cover, body, rest, io } = window.tzO;
      tzAt(150, header, "tz-in");
      tzAt(450, cover, "tz-cover");
      const [avatarRow, nameRow, ...more] = body.children;
      tzAt(1100, avatarRow, "tz-pop");
      tzAt(1500, nameRow, "tz-in");
      more.forEach((el, i) => tzAt(1800 + i * 200, el, "tz-in"));
      setTimeout(() => rest.forEach((s) => io.observe(s)), 2400);
      tzScrollTo(3000, tzTop(window.tzTags) - 120, 1100);
    });
    await page.waitForTimeout(5200);
    // Anna gives "Elixir" her vote: the count goes up, the roster opens
    const chip = page.locator("main section .flex-wrap > div").filter({ has: page.locator("a", { hasText: /^\s*Elixir\s*$/ }) }).first();
    const p = await pointer(page, START, { touch: true });
    await p.clickAt(...(await p.centre(chip.locator("[data-tag-vote-count]"))), 900);
    // a tap, then the finger lifts off the tag, so its name and new count read
    // clearly; the pointer itself stays, so the endorsers stay open
    await page.waitForTimeout(200);
    await p.hide();
    await chip.locator("[data-tag-vote-count]").evaluate((b) => { b.classList.remove("tz-beat"); void b.offsetWidth; b.classList.add("tz-beat"); });
    await page.waitForTimeout(1300);
    await page.evaluate(() => {
      let t = 200;
      for (const s of window.tzStops) {
        tzScrollTo(t, tzTop(s) - 80, 1100);
        t += 1100 + 1700;
      }
      window.tzEnd = t;
    });
    await page.waitForTimeout(await page.evaluate(() => window.tzEnd));
  });
  await ctx.close();
}

// ---------------------------------------------------------------- feed
if (wanted("feed")) {
  const ctx = await phone(MIRIAM);
  const page = await ctx.newPage();
  await page.goto(`${BASE}/feed`, { waitUntil: "networkidle" });
  await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch (e) {} });
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForFunction(() => document.querySelector(".phx-connected"));
  await dress(page);
  await hideReachPost(page, ids);
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
    await page.keyboard.type(c.post.line1, { delay: 16 });
    await page.keyboard.press("Enter");
    await page.keyboard.type(c.post.line2, { delay: 16 });
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
      await page.keyboard.type(tag, { delay: 40 });
      await page.keyboard.type(",", { delay: 40 });
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
    // the likers' avatars: photos (or initials) on the "Liked by" line; a
    // photo's ring sits on its wrapper, so the wrapper is what waits
    const line = textEl && textEl.getBoundingClientRect();
    const avatars = $$("img, span, div", focus).filter((e) => {
      const r = e.getBoundingClientRect();
      const face = e.tagName === "IMG" || /^[A-Z]{2}$/.test(e.textContent.trim());
      // on a phone "Liked by ..." wraps onto its own line below the faces
      return face && r.width > 16 && r.width < 48 && line && Math.abs(r.top + r.height / 2 - (line.top + line.height / 2)) < 44;
    }).filter((e, i, all) => !all.some((o) => o !== e && o.contains(e)))
      .map((e) => {
        const r = e.getBoundingClientRect();
        let w = e;
        while (w.parentElement && w.parentElement !== focus) {
          const q = w.parentElement.getBoundingClientRect();
          if (Math.abs(q.width - r.width) > 6 || Math.abs(q.height - r.height) > 6) break;
          w = w.parentElement;
        }
        return w;
      });
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
    // the bell's badge belongs on the tab bar, the only navigation a phone shows
    const a = $('nav[data-nav-bar="tabs"] a[href="/notifications"]');
    if (a) { const b = document.createElement("span"); b.className = "tz-badge"; a.style.position = "relative"; a.appendChild(b); window.tzBell = b; }
  }, POST);
  await page.waitForTimeout(800);
  await rec(page, "post", async () => {
    await page.evaluate(() => {
      const { focus, reply, textEl, avatars, likeCount, replyCount } = window.tz;
      const beat = (e) => { if (!e) return; e.classList.remove("tz-beat"); void e.offsetWidth; e.classList.add("tz-beat"); };
      const badge = (b, n) => { if (!b) return; b.textContent = n; b.style.opacity = 1; b.classList.remove("tz-pop"); void b.offsetWidth; b.classList.add("tz-pop"); };
      const heart = likeCount && likeCount.parentElement.querySelector("svg");
      avatars.forEach((a, i) => setTimeout(() => { a.classList.add("tz-pop"); if (likeCount) { likeCount.textContent = String(i + 1); beat(likeCount); } beat(heart); badge(window.tzBell, i + 1); }, 300 + i * 550));
      setTimeout(() => textEl && textEl.classList.add("tz-in"), 300 + avatars.length * 550);
      setTimeout(() => {
        focus.classList.remove("tz-noline");
        (window.tzLines || []).forEach((l) => (l.style.opacity = 1));
        reply && reply.classList.add("tz-in");
        if (replyCount) { replyCount.textContent = "1"; beat(replyCount); }
        badge(window.tzBell, avatars.length + 1);
      }, 300 + avatars.length * 550 + 500);
    });
    await page.waitForTimeout(4200);
    // ⋯ > "Reach analysis": the film cuts to the analysis from there
    const menu = page.locator("#thread-focus details[data-menu]").first();
    const p = await pointer(page, START, { block: 'a[href$="/analytics"]', touch: true });
    await p.clickAt(...(await p.centre(menu.locator("summary"))), 900);
    await page.waitForTimeout(600);
    await p.clickAt(...(await p.centre(menu.locator('a[href$="/analytics"]'))), 700);
    await page.waitForTimeout(500);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- reach
if (wanted("reach")) {
  const ctx = await phone(MIRIAM);
  const page = await open(ctx, `/posts/${ids.reach_post_id}/analytics`);
  await page.addStyleTag({ content: `
    footer { visibility: hidden !important; }
    [data-repost-reach-bar] { transition: width .9s cubic-bezier(.2,.8,.2,1); }` });
  await page.evaluate(() => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    const head = $("main div.mb-7"), reachSec = $("main section");
    const bars = $$("[data-repost-reach-bar]");
    bars.forEach((b) => { b.dataset.w = b.style.width; b.style.width = "0%"; });
    [head, reachSec].forEach((e) => e.classList.add("tz-h"));
    window.tzR = { head, reachSec, bars };
  });
  await page.waitForTimeout(800);
  await rec(page, "reach", async () => {
    await page.evaluate(() => {
      const { head, reachSec, bars } = window.tzR;
      tzAt(100, head, "tz-in");
      tzAt(350, reachSec, "tz-in");
      // the bars sit below the big figure on a phone: bring them up while they grow
      tzScrollTo(900, tzTop(reachSec) - 60, 1000);
      bars.forEach((b, i) => setTimeout(() => (b.style.width = b.dataset.w), 1200 + i * 70));
    });
    await page.waitForTimeout(4100);
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
  await rec(page, "jobs", async (mark) => {
    await page.evaluate(() => {
      const { head, form, chips, tags, cards } = window.tzE;
      tzAt(150, head, "tz-in"); tzAt(450, form, "tz-in"); tzAt(750, chips, "tz-in");
      tags.forEach((t, i) => tzAt(950 + i * 80, t, "tz-pop"));
      cards.forEach((c, i) => tzAt(1300 + i * 300, c, "tz-in"));
    });
    await page.waitForTimeout(1500);
    // the list sits below the form on a phone: a look at it before the search
    await page.evaluate(() => {
      const first = window.tzE.cards[0];
      tzScrollTo(0, tzTop(first) - 90, 900);
      tzScrollTo(1900, 0, 900);
    });
    await page.waitForTimeout(2900);
    const p = await pointer(page, START, { touch: true });
    const q = page.locator('main input[name="q"]');
    await reach(page, q, 0.35);
    await p.clickAt(...(await p.centre(q)), 900);
    await page.keyboard.type(c.search.q, { delay: 60 });
    await page.waitForTimeout(300);
    await p.clickAt(...(await p.centre(page.locator('main input[name="near"]'))), 700);
    await page.keyboard.type(c.search.near, { delay: 60 });
    await page.waitForTimeout(400);
    const submit = page.locator('main form button[type="submit"]').first();
    await reach(page, submit, 0.55);
    await p.clickAt(...(await p.centre(submit)), 700);
    mark("search");
    await page.waitForURL(/[?&]q=/i, { timeout: 15000 });
    await page.waitForLoadState("domcontentloaded");
    await page.waitForTimeout(150);
    await page.addStyleTag({ content: CSS });
    await page.evaluate(HELPERS);
    await page.evaluate(HIDE_REAL_JOBS, ORGS);
    await page.waitForLoadState("networkidle");
    await page.evaluate(() => { window.tzHideCounts(); window.scrollTo(0, 0); });
    await page.waitForTimeout(300);
    // the new page is dressed: from here on the film may show it
    mark("results");
    await page.waitForTimeout(400);
    // the results sit below the form on a phone: down to the first two
    await page.evaluate(() => {
      const cards = [...document.querySelectorAll("main article")].filter((a) => a.style.display !== "none");
      if (cards[0]) tzScrollTo(0, tzTop(cards[0]) - 90, 1200);
    });
    await page.waitForTimeout(3000);
  });
  await ctx.close();
}

await browser.close();
