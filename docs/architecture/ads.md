# Daily text ad (`Vutuv.Ads`)

One discreet, text-only ad per calendar day (Europe/Berlin via the fixed EU DST
rule, no tz dependency) in the style of classic text ads, always labeled
"Ad"/"Anzeige": a title of up to 30 characters that links to the booked page
(new tab, `rel="sponsored"`), one plain sentence of up to 90, and the address
the link goes to (`Vutuv.Ads.Ad.display_url/1`: host without `www.` plus path,
never the query). No Markdown, so no mentions or hashtags either. An ad booked
in the Markdown format before that has no title and never serves; its
`content` column is nullable and goes in a later deploy.

## Where it shows

Only on a **profile** and in the **feed**, the two pages people spend their
time on. Both are LiveViews rendered by their controller, and each carries the
card (`VutuvWeb.AdComponents.ad_card/1`) twice: at the top of the rail on a
desktop, and on a phone, where there is no rail, under the profile header or
under the feed's control row. The phone copy sits outside the timeline, so
posts arriving behind the pill never push it around. Every other page is
ad-free.

The request decides (`VutuvWeb.AdServing.serve/1`, called by `UserController`
and `NewsfeedController`) and hands its choice to the socket in the curated
session map (`AdServing.session/1`, merged in by the two controllers).
`VutuvWeb.Live.AdSlot` (an `on_mount`) shows exactly that and does not ask the
frequency rules again on connect. It re-reads only whether the ad may still
serve (`Vutuv.Ads.todays_ad/1`), so a tab reconnecting after midnight does not
bring yesterday's ad back, and a reconnect more than an hour after the request
shows no card at all.

On unbooked days a short house ad sells the slot.

## How often

- **At most one ad an hour** (`Vutuv.Ads.eligible?/3`), counted from a card
  that was **seen**: the `AdSlot` hook reports the first moment a card is at
  least half in view. Sending a page takes nothing. For a member the hour is
  `users.ad_seen_at`, on the server and shared by every device, and
  `Vutuv.Ads.record_sighting/3` takes it only while it is free, so a second
  tab whose card comes into view within the hour loses that card.
- **The ✕ ends ads for the day** (Berlin midnight), `users.ads_dismissed_on`.
- **A visitor without an account sees the ad on every profile** (the feed
  needs an account). No cookie, no
  session entry, nothing on the server: their ✕ ("Close this ad") takes away
  only the card in front of them.
- Without JavaScript nobody reports a sighting, so such a browser sees the
  card on every such page, and it never goes by itself.
- The card **goes after two minutes of being seen**. A ring around the ✕
  empties (`assets/js/ad_slot.js`), counting only time in which the card is at
  least half in view in a tab that is in front, and standing still while the
  pointer or the keyboard focus is on the card; its timer runs only while the
  card is in view. Then the hook sends `"ad-expired"` and `phx-remove` fades
  the card out. The countdown is kept per served card (`data-ad-key`) for the
  page load, shared by the two copies; a card the server draws again after it
  ran out goes at once, and an event lost while the socket
  was down is sent again from `reconnected()`.
- No ad while the one-time welcome questions cover the page.

## What is stored, and the seen-ads page

`ad_sightings` keeps one row per member and **booked** ad (first and last
sighting, count), written by `Vutuv.Ads.record_sighting/3` on `"ad-seen"`. The
house ad stamps the hour and leaves no row. Rows go with the member's account
(`on_delete: :delete_all`), are part of the personal data export
(`seen_ads`), and are forgotten 90 days after they were last seen
(`Vutuv.Ads.SightingSweeper`, daily, first run ten minutes after boot;
`config :vutuv, :sweep_ad_sightings`).

The card's "Ad" label is a link. A member lands on **`/system/ads/seen`**
(`VutuvWeb.AdsSeenLive`, login only, noindex, 404 while the system is off):
the ads they saw, the most recently seen first, each with when it was last
seen and how often, a search over title, text and address, and "Load more" in pages of 20
(`Vutuv.Ads.seen_ads/2`). A visitor has no history, so their label leads to
the `/system/ads` offer page instead; there is no public archive of past ads, which
would keep a one-day booking on show for months.

## Booking and review

Booking is the three-step wizard `VutuvWeb.AdBookingLive` at `/system/ads/new`
(logged-in only): **write the ad**, **pick when it runs**, **say where the
invoice goes**. It is a LiveView because the one question a buyer has is what
the thing will look like, and the card is drawn from what they are typing by
the very component a profile and the feed use — the dead form it replaced
answered that on a separate page, after everything else had been filled in.

The text can be **saved and used again** (`ad_creatives`, `Vutuv.Ads.Creative`,
at most `creative_cap/0` per member). Booking **copies** the text onto the
`ads` rows rather than pointing at the saved one, so editing a saved ad can
never rewrite an ad that is already running, already approved, or already on an
invoice; a test pins that. Both meet the same rules, because
`Vutuv.Ads.Ad.validate_text/1` is the one owner of them — a library that lets
you save what the booking then refuses is the one thing it must not do.

The last step says what we reserve, where the reader agrees to the money and
not in a page of terms elsewhere: the booking is binding, **we may turn it down
without giving a reason** (then it does not run and nothing is charged), and an
**unpaid invoice takes the ad off the site**. It also asks **which of the
member's addresses the invoice goes to** (`ads.invoice_email`; radios above two,
a stated line for one). That choice is re-checked against
`Vutuv.Accounts.list_email_values/1` in `book_ad/3` — the same allow-list the
username-rename confirmation uses, and for the same reason: otherwise "where
should we mail this" is a form field pointing at anybody's mailbox. A value that
is not the member's own falls back to their first address, so a tampered one can
only ever reach them. The operator mail, which the invoice is written from,
names it.

The calendar shows **this month and the next three**
(`last_bookable_day/0`) and works in the unit being bought: with a week chosen,
only a day with seven free days behind it is rendered as a control
(`free_block?/3`), picking it marks all seven, and hovering marks them too,
client-side (`assets/js/ad_calendar.js`, `.is-block-hover`). Changing the
length **drops** a start it no longer fits rather than quietly booking a
stretch nobody picked. A day taken while the invoice was being typed sends the
member back to the calendar with it struck through, not to an error page.

350 € net per day plus VAT (`ADS_VAT_PERCENT`, default the German 19 %; `0`
drops the VAT line everywhere), payment by invoice: the booking mail (billing data + ad)
goes to the operator, who invoices manually, and the booker gets a receipt.
The price is stamped on the row, so "My bookings" and the review pages show
what was booked rather than today's price.

**A week and a month are cheaper per day, and are still one row per day.**
`Vutuv.Ads.tiers/0` is the whole price list — 1 day 350 €, 7 days 2.000 €,
30 days 7.500 €, net — and every quoted figure on the offer page, in the
booking form, in the preview and in both mails is derived from it, so nothing
can quote three different numbers. A block is N rows sharing a `group_id`,
inserted in one transaction: a day somebody else took in the meantime fails the
whole purchase rather than leaving a member holding four days of the week they
paid for, and the error is reported about the day they picked, not about the
seventh day they never saw. The tier price is split over the rows so the shares
add up to it exactly (the remainder rides the first day); nobody reads a share,
but a day cancelled out of a block has to leave the rest adding up to something
real. **One decision moves the whole purchase**, and that lives in the private
`move/3` alone, so approving, rejecting and both cancellation paths inherit it
together and the booker hears once rather than seven times. The admin table
says so on every row of a block, or an admin presses one button and watches six
other rows change. There is one slot a day, so a month sold is a month nobody
else can buy — which is why the month is the bigger discount and why widening
the tier list is a product decision, not a constant. Days on these pages are written the
way the reader writes dates (`VutuvWeb.AdHTML.day_label/1`); the offer page
wraps them in `<time datetime>`, which keeps the ISO date for its agent-format
siblings.

**Taking an ad off the site while it runs** is a second, deliberate act beside
the free cancellation (`withdraw_booking/2` against `cancel_booking/2`). One is
free because nothing was promised yet, the other costs the whole booking, and a
single function with a branch in it would let a caller reach the expensive one
by accident. It stops the ad from today, leaves days that already ran as
history, and gives **no money back**; a `<dialog>` on the bookings page says so
before the act is reachable, because what has to be read is the price of it and
a `data-confirm` gives one unstyled line. Its operator notice is its own
message: the cancellation one asks for a credit note, this one says the invoice
stands. "My ads" sits in the account menu (`ShellLive`), but only while
`Ads.enabled?` — every `/system/ads` page 404s otherwise, and a menu item into
a 404 is worse than none.

**Discount codes** (`Vutuv.Ads.Discounts`, `/admin/ads/discounts`): the code IS
the row's id, a UUID v7, so nothing can collide and nobody can guess one.
Percent **or** euro, never both (1–100 %, 1–3.000 €), enforced by a database
`CHECK` as well as the changeset, because the money must not depend on a
validation somebody forgets. A code with a `user_id` belongs to that member and
is good once; one without may be used by anybody, **once each**. Redemptions are
rows, not a counter — "once per member" is a fact about a pair, and the partial
unique index on `(code_id, user_id) where released_at IS NULL` is what enforces
both readings of it. A booking we turn down, or one cancelled before approval,
**releases** the code (nothing ran); a withdrawal after approval does not. The
discount is **stamped beside the price** (`ads.discount_cents`), not folded into
it, so an invoice is not rewritten when a code later expires or is deleted, and
it comes off the **net** — the wizard's summary recomputes the VAT on the
reduced amount. Every rule about whether a code may be used lives in
`Discounts.check/3`, which the wizard asks to SHOW a price and `book_ad/3` asks
again before it stamps one. A code that turns out unusable books at the list
price rather than failing the booking: nobody loses their week over a typo in a
voucher.

**Every ad is reviewed before it runs.** A booking is pending, then approved
or rejected, and it can be cancelled on the way (`Vutuv.Ads.Ad.status/1`):

- **Approve** (`approve_ad/2`): the ad serves on its day, the booking is
  binding from here on, and the booker is told.
- **Reject** (`reject_ad/3`): only while pending, and only with a reason (up
  to 2,000 characters), which the booker reads. Nothing is invoiced.
- **Cancel**: the booker may while the booking is pending
  (`cancel_booking/2`, a button on `/system/ads/bookings`), and the operator
  is told, since the invoice may already be out. An admin may cancel any
  booking before its day (`cancel_ad/2`), and the booker is told.

Every move is one conditional `UPDATE`, so an admin and the booker acting at
once cannot both win. A rejected or cancelled booking frees its day: the
unique index on `day` covers only the standing bookings
(`rejected_at IS NULL AND cancelled_at IS NULL`), and every "is this day
taken" question goes through the same query. The mails to the booker come in
their language (`ad_booked`, `ad_approved`, `ad_rejected`, `ad_cancelled`);
the operator's three (`ad_booking`, `ad_cancellation`, `ad_withdrawal`) are
German. The booking notice ends with **everything still waiting for approval**
(`pending_purchases/0`, soonest first, one line per purchase rather than per
day): the mail that says one ad arrived is then also the only place that says
what else is outstanding, so an admin who reads one away still knows what came
in while they were gone.

The review dashboard lives at `/admin/ads` (with a pending badge on the admin
panel), the booker's view at `/system/ads/bookings`, and the earliest bookable
day is **three days out** to leave room for the review.

**Numbers.** Each ad counts `views_count` and `clicks_count`, sums only and
never who. A view is a card at least half in view: once per page for a
visitor, and with the sighting for a member, so it respects their hourly
limit. A click is the first click on the title link per page, which the hook
reports because the link opens a new tab and the page is still there. The
booker sees both from the ad's day on, admins on the review pages. Without
JavaScript nothing is counted.

Bookings are accepted only inside the **booking window** (through the end of
next month); the booking form shows it as month-grid calendars with free days as
radio buttons and booked days struck through, and submits to a **preview step**
that renders the ad through the real card (without its ✕ and its two-minute
hook) before the binding confirm POST books it.

`/system/ads` is a public page with agent-format siblings
(`VutuvWeb.AgentDocs.AdsDoc`).

The whole system sits behind a global switch (`config :vutuv, :ads_enabled`,
read via `Vutuv.Ads.enabled?/0`), **off by default**: with it off no ad
serves and the `/system/ads` flow plus the `/admin/ads` review dashboard 404, while
`"ads"` stays a reserved username slug so the handle is kept free
