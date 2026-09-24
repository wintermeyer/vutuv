// Logs a fictional member in through the real PIN flow and saves the session.
//   node scripts/teaser/login.mjs <email> <state.json>
// The PIN is read from the dev mailbox (/sent_emails/json), picking the newest
// mail to that address.
import { chromium } from "playwright";
import { BASE } from "./lib.mjs";

const [email, statePath] = process.argv.slice(2);
const browser = await chromium.launch({ channel: "chrome" });
const ctx = await browser.newContext();
const page = await ctx.newPage();
await page.goto(`${BASE}/login`);
await page.fill('input[type="email"], input[name*="email"]', email);
await Promise.all([page.waitForLoadState("networkidle"), page.keyboard.press("Enter")]);
await page.waitForTimeout(1500);
const mails = (await (await page.request.get(`${BASE}/sent_emails/json`)).json()).data;
const mine = mails.filter((m) => JSON.stringify(m.to).includes(email));
const pin = ((mine[0]?.text_body || "").match(/^\s+(\d{6})\s*$/m) || [])[1];
if (!pin) throw new Error(`no PIN mail for ${email}`);
await page.fill('input[name*="pin"], input[autocomplete="one-time-code"]', pin);
await Promise.all([page.waitForLoadState("networkidle"), page.keyboard.press("Enter")]);
await page.waitForTimeout(1500);
if (/\/login/.test(page.url())) throw new Error(`login for ${email} did not go through (${page.url()})`);
await ctx.storageState({ path: statePath });
console.log("logged in", email);
await browser.close();
