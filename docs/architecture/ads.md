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

Booking is online at `/system/ads` → `/system/ads/new` (logged-in only): pick a free day (one
ad/day, unique index), enter the invoice address, then title, sentence and link
(must be family-friendly; live counters for the two limits, the changeset
enforces them and accepts only an http(s) link to a public host).

1.250 € net per day, payment by invoice: the booking mail (billing data + ad
text) goes to the operator, who invoices manually; serving on the booked day is
automatic.

**Every ad is admin-approved before it runs** (`approved_at`; an unapproved ad
never serves, the house ad fills its day): the review dashboard lives at
`/admin/ads` (with a pending badge on the admin panel), the member sees the
approval state of their bookings at `/system/ads/bookings`, and the earliest bookable
day is **three days out** to leave room for the review.

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
