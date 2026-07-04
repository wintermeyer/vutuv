# Daily text ad (`Vutuv.Ads`)

One discreet, text-only ad per calendar day (Europe/Berlin via the fixed EU DST
rule, no tz dependency), rendered between the top navigation and the content in
the style of classic text ads, always labeled "Ad"/"Werbung".

A visitor sees it at most **once per hour** (session-tracked, and only counted
when the banner actually rendered), it hides itself after **two minutes**
(app.js), and its **✕ dismisses ads for the rest of the day** (a day-stamped
client cookie the plug honors).

On unbooked days a short house ad sells the slot.

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
that renders the ad through the real banner component (without its
auto-hide/seen-marker hooks) before the binding confirm POST books it.

`/ads` is a public page with agent-format siblings
(`VutuvWeb.AgentDocs.AdsDoc`).

The whole system sits behind a global switch (`config :vutuv, :ads_enabled`,
read via `Vutuv.Ads.enabled?/0`), **off by default**: with it off no banner
serves and the `/ads` flow plus the `/admin/ads` review dashboard 404, while
`"ads"` stays a reserved username slug so the handle is kept free
