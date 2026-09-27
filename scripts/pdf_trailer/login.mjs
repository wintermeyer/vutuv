// Logs the fictional member in through the real PIN flow and saves the session.
//   node scripts/pdf_trailer/login.mjs <state.json>
// The PIN is read from the dev mailbox (/sent_emails/json), newest mail first.
import { chromium } from "playwright";

const BASE = process.env.TRAILER_BASE || "http://localhost:4078";
const EMAIL = "clara.neumann@example.com";
const [statePath] = process.argv.slice(2);

const browser = await chromium.launch({ channel: "chrome" });
const ctx = await browser.newContext({ locale: "de-DE", extraHTTPHeaders: { "Accept-Language": "de-DE,de" } });
const page = await ctx.newPage();
await page.goto(`${BASE}/login`);
await page.fill('input[type="email"], input[name*="email"]', EMAIL);
await Promise.all([page.waitForLoadState("networkidle"), page.keyboard.press("Enter")]);
await page.waitForTimeout(1500);
const mails = (await (await page.request.get(`${BASE}/sent_emails/json`)).json()).data;
const mine = mails.filter((m) => JSON.stringify(m.to).includes(EMAIL));
const pin = ((mine[0]?.text_body || "").match(/^\s+(\d{6})\s*$/m) || [])[1];
if (!pin) throw new Error(`no PIN mail for ${EMAIL}`);
await page.fill('input[name*="pin"], input[autocomplete="one-time-code"]', pin);
await Promise.all([page.waitForLoadState("networkidle"), page.keyboard.press("Enter")]);
await page.waitForTimeout(1500);
if (/\/login/.test(page.url())) throw new Error(`login did not go through (${page.url()})`);
await ctx.storageState({ path: statePath });
console.log("logged in", EMAIL);
await browser.close();
