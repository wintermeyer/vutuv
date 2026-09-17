# Daily text ad (`Vutuv.Ads`)

One discreet, text-only ad per calendar day (Europe/Berlin via the fixed EU DST
rule, no tz dependency) in the style of classic text ads, always labeled
"Ad"/"Anzeige".

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
`VutuvWeb.Live.AdSlot` (an `on_mount`) shows exactly that and does not ask
again on connect: by then the request has already taken the visitor's hour.
It re-reads only whether the ad may still serve (`Vutuv.Ads.todays_ad/1`), so
a tab reconnecting after midnight does not bring yesterday's ad back.

On unbooked days a short house ad sells the slot.

## How often

- **At most one ad an hour.** For a member this is `users.ad_seen_at`, kept on
  the server and so shared by every device (`Vutuv.Ads.eligible?/3`); a
  visitor without an account keeps it in the session. The hour is taken in a
  `before_send` hook, only when the page goes out with status 200.
- **The ✕ ends ads for the day** (Berlin midnight). For a member it is
  `users.ads_dismissed_on`; the ✕ also writes the day into the unsigned
  cookie `vutuv_ad_dismissed` on the click, which is all a visitor has.
- The card **goes after two minutes**, counted from the request that served
  it: the session carries that second (`"ad_served_at"`), the LiveView
  schedules the end, and `phx-remove` fades the card out. A reconnect after
  that shows no card; one after a ✕ is sent away by the `AdSlot` hook in
  `assets/js/ad_slot.js`, which reads the day cookie the socket cannot.
- No ad while the one-time welcome questions cover the page.

## What is stored

`ad_sightings` keeps one row per member and **booked** ad (first and last
sighting, count), written by `Vutuv.Ads.record_sighting/3`: the base for a
member's history of seen ads and for per-ad reach. The house ad stamps the
hour and leaves no row. Rows go with the member's account (`on_delete:
:delete_all`); nothing is stored per visitor on the server.

## Booking and review

Booking is online at `/ads` → `/ads/new` (logged-in only): pick a free day (one
ad/day, unique index), enter the invoice address, ad text as Markdown (max 2048
chars, must be family-friendly, rendered through `VutuvWeb.Markdown`).

1.250 € net per day, payment by invoice: the booking mail (billing data + ad
text) goes to the operator, who invoices manually; serving on the booked day is
automatic.

**Every ad is admin-approved before it runs** (`approved_at`; an unapproved ad
never serves, the house ad fills its day): the review dashboard lives at
`/admin/ads` (with a pending badge on the admin panel), the member sees the
approval state of their bookings at `/ads/bookings`, and the earliest bookable
day is **three days out** to leave room for the review.

Bookings are accepted only inside the **booking window** (through the end of
next month); the booking form shows it as month-grid calendars with free days as
radio buttons and booked days struck through, and submits to a **preview step**
that renders the ad through the real card (without its ✕ and its two-minute
hook) before the binding confirm POST books it.

`/ads` is a public page with agent-format siblings
(`VutuvWeb.AgentDocs.AdsDoc`).

The whole system sits behind a global switch (`config :vutuv, :ads_enabled`,
read via `Vutuv.Ads.enabled?/0`), **off by default**: with it off no ad
serves and the `/ads` flow plus the `/admin/ads` review dashboard 404, while
`"ads"` stays a reserved username slug so the handle is kept free
