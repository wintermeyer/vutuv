# Consent blocker for the screenshot browser

Without it, a large share of link-preview captures are a picture of a
cookie-consent dialog instead of the page. `Vutuv.PageScreenshot.Consent`
injects the bundle here into every frame of the capture; it finds the site's
consent manager, hides it, and clicks **reject**.

Both files are **generated and gitignored**, copied verbatim from
`@duckduckgo/autoconsent` by `mix vutuv.autoconsent.vendor` (the last step of
`mix assets.setup`):

- `autoconsent.js` — `dist/autoconsent.playwright.js`, the host-driven build.
  It asks us for its config and rules over a binding and reports back when the
  opt-out has finished, which is what lets the capture wait for the dialog to
  actually go rather than guessing a delay.
- `rules.json` — `dist/addon-mv3/rules.json`, the CMP rule set it asks for.

We override none of its defaults except turning its logging off:
`autoAction: "optOut"` rejects and never accepts (we do not consent to tracking
on a member's behalf), `enablePrehide` hides the dialog at `document_start` so
a shot is clean even before the click lands, and `enableCosmeticRules` covers
CMPs that have no clickable opt-out.

Upgrading is `npm update @duckduckgo/autoconsent` in `assets/` plus a re-run of
`mix assets.setup`. Licensed MPL-2.0; we ship it unmodified.
