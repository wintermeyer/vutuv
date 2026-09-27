// Records the desktop (16:9) scenes of the teaser from the running teaser server.
//
//   node scripts/teaser/record.mjs <lang> [scene ...]
//
// Scenes (see README.md for the storyboard):
//   profile  Miriam's profile as Anna sees it: it builds itself, Anna gives a tag
//            her vote, then on down to the CV, book reviews and links
//   feed     Miriam likes + reposts the news, writes her post, bolds a line, tags, posts
//   post     her post page: likes pop in, Anna replies, then ⋯ > "Reach analysis"
//   reach    the reach analysis of an older post: its repost reach bars grow
//   jobs     the job board: search "Elixir" in her city, the list swaps to the jobs there
//   outro    three phone screenshots (profile top, feed, job results) for the end
// Without scene names it records all of them. Needs _build/teaser/<lang>/ids.json
// (seed.exs) and state-*.json (login.mjs).
import { chromium } from "playwright";
import fs from "fs";
import path from "path";
import { ROOT, BASE, CSS, HELPERS, DESKTOP, launch, loadContent, newContext, open, dress, record, pointer,
  stammtischNeedles, HIDE_OTHER_STAMMTISCH, jobOrgs, HIDE_REAL_JOBS, hideReachPost, recordOutro } from "./lib.mjs";

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
// ---------------------------------------------------------------- reach
if (wanted("reach")) {
  const ctx = await newContext(browser, lang, MIRIAM);
  const page = await open(ctx, `/posts/${ids.reach_post_id}/analytics`);
  await page.addStyleTag({ content: `
    footer { visibility: hidden !important; }
    [data-repost-reach-bar] { transition: width .9s cubic-bezier(.2,.8,.2,1); }` });
  await page.evaluate(() => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    const head = $("main div.mb-7"), reachSec = $("main section");
    // the reach bars start empty
    const bars = $$("[data-repost-reach-bar]");
    bars.forEach((b) => { b.dataset.w = b.style.width; b.style.width = "0%"; });
    [head, reachSec].forEach((e) => e.classList.add("tz-h"));
    window.tzR = { head, reachSec, bars };
  });
  await page.waitForTimeout(800);
  await record(page, path.join(REC, "reach"), async () => {
    await page.evaluate(() => {
      const { head, reachSec, bars } = window.tzR;
      tzAt(100, head, "tz-in");
      tzAt(350, reachSec, "tz-in");
      bars.forEach((b, i) => setTimeout(() => (b.style.width = b.dataset.w), 700 + i * 70));
    });
    // all bars grown, then a moment to read them
    await page.waitForTimeout(3600);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- outro phones
if (wanted("outro")) await recordOutro(browser, lang, c, ids, { miriam: MIRIAM, anna: ANNA, screens: SCREENS });

// ---------------------------------------------------------------- feed
if (wanted("feed")) {
  const ctx = await newContext(browser, lang, MIRIAM);
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
    await page.waitForTimeout(1100);
    await p.clickAt(...(await p.centre(page.locator("#open-composer"))), 900);
    await page.waitForSelector("#composer-form", { state: "visible" });
    await page.evaluate(() => { const s = document.querySelector("#composer-form").closest("section") || document.querySelector("#composer-form"); s.classList.remove("tz-in"); void s.offsetWidth; s.classList.add("tz-in"); });
    await page.waitForTimeout(800);
    const editor = page.locator("#composer-form [contenteditable=true]:visible").first();
    const eb = await editor.boundingBox();
    await p.clickAt(eb.x + 40, eb.y + 30, 500);
    await page.keyboard.type(c.post.line1, { delay: 16 });
    await page.keyboard.press("Enter");
    await page.keyboard.type(c.post.line2, { delay: 16 });
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
      await page.keyboard.type(tag, { delay: 40 });
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
    // the likers' avatars: photos (or initials) on the "Liked by" line
    const line = textEl && textEl.getBoundingClientRect();
    const avatars = $$("img, span, div", focus).filter((e) => {
      const r = e.getBoundingClientRect();
      const face = e.tagName === "IMG" || /^[A-Z]{2}$/.test(e.textContent.trim());
      return face && r.width > 20 && r.width < 48 && line && Math.abs(r.top + r.height / 2 - (line.top + line.height / 2)) < 16;
    }).filter((e, i, all) => !all.some((o) => o !== e && o.contains(e)))
      // a photo's ring sits on its wrapper: hide the wrapper, or an empty ring shows
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
    const p = await pointer(page, [1000, 640], { block: 'a[href$="/analytics"]' });
    await p.clickAt(...(await p.centre(menu.locator("summary"))), 900);
    await page.waitForTimeout(600);
    await p.clickAt(...(await p.centre(menu.locator('a[href$="/analytics"]'))), 700);
    await page.waitForTimeout(500);
  });
  await ctx.close();
}

const ORGS = jobOrgs(c);

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
    await page.keyboard.type(c.search.q, { delay: 60 });
    await page.waitForTimeout(300);
    await p.clickAt(...(await p.centre(page.locator('main input[name="near"]'))), 700);
    await page.keyboard.type(c.search.near, { delay: 60 });
    await page.waitForTimeout(300);
    await page.waitForTimeout(600);
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
    // the results are the point; the edit cuts to her CV from here
    await page.waitForTimeout(2400);
  });
  await ctx.close();
}

// ---------------------------------------------------------------- profile
if (wanted("profile")) {
  // Anna visits: a visitor's tag counts are buttons, and she gives one a vote
  const ctx = await newContext(browser, lang, ANNA);
  const page = await open(ctx, "/miriam_kessler");
  await hideReachPost(page, ids);
  await page.addStyleTag({ content: `
    #profile-job-references, #profile-qualifications, #profile-press, #profile-about, #profile-messengers,
    #profile-addresses, #profile-who-to-follow, #profile-other-formats, #profile-following, #profile-followers,
    #profile-education, #profile-languages,
    #profile-posts div:has(> #composer-panel),
    main [class*=border-dashed] { display: none !important; }` });
  // The vote re-renders the LiveView, and the patch strips every class the
  // recorder added: what has finished building stays, what is still hidden
  // shows at once. So everything before the vote has built itself by the time
  // of the click, and what comes after it is held back by a rule in <head>,
  // which a patch never touches.
  const LATER = ["#profile-book-reviews", "#profile-links"];
  await page.addStyleTag({ content: `${LATER.join(", ")} { opacity: 0; }` });
  await page.evaluate((LATER) => {
    const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
    window.scrollTo(0, 0);
    const later = LATER.map((s) => $(s));
    const secs = $$("main section").filter((s) => getComputedStyle(s).display !== "none" && s.getBoundingClientRect().height > 0 && !later.includes(s));
    const header = secs[0];
    const cover = header.children[0], body = header.children[1];
    const tags = secs.find((s) => s.querySelector("h2")?.textContent.trim() === "Tags");
    const code = $("#profile-code-stats"), sposts = $("#profile-social-posts");
    const repoRows = code ? [...code.querySelectorAll(".divide-y > div > *")] : [];
    const postRows = sposts ? [...sposts.querySelectorAll("article, li")] : [];
    const exp = $("#profile-experience");
    const group = exp.querySelector("div.relative.ml-5");
    const subs = group ? [...group.children].filter((c) => c.tagName === "DIV") : [];
    const bubbles = $$(".rounded-full", exp).filter((b) => b.offsetWidth > 25);
    [...secs, cover, ...body.children, ...$$(".flex-wrap > div", tags), ...repoRows, ...postRows, ...subs, ...bubbles].forEach((p) => p.classList.add("tz-h"));
    window.tzO = { secs, header, cover, body, tags, repoRows, postRows, exp, subs, bubbles };
  }, LATER);
  await page.waitForTimeout(800);
  await record(page, path.join(REC, "profile"), async () => {
    // 1. the top of the profile, her tags and her CV
    await page.evaluate(() => {
      const { secs, header, cover, body, tags, repoRows, postRows, exp, subs, bubbles } = window.tzO;
      tzAt(150, header, "tz-in");
      tzAt(450, cover, "tz-cover");
      const [avatarRow, nameRow, ...rest] = body.children;
      tzAt(1100, avatarRow, "tz-pop");
      tzAt(1500, nameRow, "tz-in");
      rest.forEach((el, i) => tzAt(1800 + i * 200, el, "tz-in"));
      secs.filter((s) => s.getBoundingClientRect().left > 800).forEach((s, i) => tzAt(800 + i * 350, s, "tz-in"));
      repoRows.forEach((r, i) => tzAt(1900 + i * 150, r, "tz-in"));
      postRows.forEach((r, i) => tzAt(2400 + i * 200, r, "tz-in"));
      secs.filter((s) => s !== header && s.getBoundingClientRect().left < 800 && s !== tags && s !== exp).forEach((s) => tzAt(2300, s, "tz-in"));
      tzAt(2600, tags, "tz-in");
      [...tags.querySelectorAll(".flex-wrap > div")].forEach((el, i) => tzAt(2900 + i * 110, el, "tz-pop"));
      tzScrollTo(3000, tzTop(tags) - 90, 1100);
      // the CV fills the column under the tags before Anna votes
      tzAt(3000, exp, "tz-in");
      bubbles.forEach((b, i) => tzAt(3300 + i * 200, b, "tz-pop"));
      subs.forEach((s, i) => tzAt(3350 + i * 120, s, "tz-in"));
    });
    await page.waitForTimeout(4400);
    // 2. Anna gives "Elixir" her vote: the count goes up, the roster opens
    const chip = page.locator("main section .flex-wrap > div").filter({ has: page.locator("a", { hasText: /^\s*Elixir\s*$/ }) }).first();
    const p = await pointer(page, [1100, 600], {});
    await p.clickAt(...(await p.centre(chip.locator("[data-tag-vote-count]"))), 900);
    // off the number, along the chip's bottom padding: the new count shows, the
    // roster stays open, and the pointer never crosses the name (a link, which
    // would underline)
    const box = await chip.boundingBox();
    const [px] = p.pos();
    await p.glide(px, box.y + box.height - 3, 150);
    await p.glide(box.x + 5, box.y + box.height - 3, 300);
    await chip.locator("[data-tag-vote-count]").evaluate((b) => { b.classList.remove("tz-beat"); void b.offsetWidth; b.classList.add("tz-beat"); });
    await page.waitForTimeout(600);
    await p.glide(1180, 690, 400);
    await p.hide();
    // 3. on down: her book reviews beside her links
    await page.evaluate((LATER) => {
      const $ = (s, r = document) => r.querySelector(s);
      const [books, links] = LATER.map((s) => $(s));
      const bookRows = books ? [...books.querySelectorAll("li")] : [];
      const linkCards = links ? [...links.querySelectorAll("div.grid > div")] : [];
      [books, links, ...bookRows, ...linkCards].filter(Boolean).forEach((e) => e.classList.add("tz-h"));
      [...document.head.querySelectorAll("style")].filter((s) => s.textContent.includes("#profile-book-reviews, #profile-links")).forEach((s) => s.remove());
      // the rail is shorter than the column: first to her book reviews, then
      // on down to her links, the screenshots of her sites
      if (books) {
        tzScrollTo(0, tzTop(books) - 80, 900);
        tzAt(0, books, "tz-in");
        bookRows.forEach((r, i) => tzAt(250 + i * 220, r, "tz-in"));
      }
      if (links) {
        tzScrollTo(1500, tzTop(links) - 70, 1000);
        tzAt(1300, links, "tz-in");
        linkCards.forEach((c, i) => tzAt(1900 + i * 220, c, "tz-pop"));
      }
    }, LATER);
    // the chapter card follows straight on
    await page.waitForTimeout(3500);
  });
  await ctx.close();
}

await browser.close();
