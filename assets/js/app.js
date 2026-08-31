// Include phoenix_html to handle method links such as `method: :delete`
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
// Desktop-only keyboard shortcuts + the "?" help overlay (self-contained,
// gated off touch devices; see keyboard_shortcuts.js).
import "./keyboard_shortcuts"
// Passkey (WebAuthn/FIDO2) login + enrolment ceremony on /login and /settings
// (self-contained, reveals itself only on supporting browsers; see webauthn.js).
import "./webauthn"
// Avatar/cover crop modal on the profile editor (self-contained progressive
// enhancement of the two file inputs; see image_crop.js).
import "./image_crop"
// Ratio crop dialog for post photos, opened from the composer's photo tiles
// by the PhotoStrip hook below (see photo_crop.js).
import { openPhotoCropper } from "./photo_crop"
// Shared plumbing (CSRF token, page lifecycle, "wire once" guard, CSRF fetch,
// reduced-motion) reused by every classic-page enhancement below.
import {
  b64urlToBuf,
  cancelIdle,
  csrfToken,
  localGet,
  localSet,
  onReady,
  once,
  postJSON,
  request,
  reducedMotion,
  savesData,
  whenIdle,
} from "./util"
// The Milkdown WYSIWYG Markdown editor shared by the post + message composers
// (VutuvWeb.UI.markdown_editor/1) is deliberately NOT imported here: it is a
// separate esbuild entry point, fetched on demand by the MarkdownEditor hook
// below. See the esbuild block in config/config.exs for the measurements.
// The tag pill box shared by every field that takes a batch of tags
// (VutuvWeb.UI.tag_input/1); registered as the TagInput hook below and swept
// over classic pages further down. See tag_input.js.
import { TagInput, enhanceTagInput } from "./tag_input"
// The photo lightbox on the post permalink (self-contained page-level
// enhancement, deliberately outside every LiveView root; see lightbox.js).
import "./lightbox"
// The phone tab bar's Feed tab as a back-to-top control once /feed is scrolled
// (self-contained; marks <html>, which is outside every LiveView root, so no
// patch can drop the state. See scroll_top_tab.js).
import "./scroll_top_tab"

// LiveSocket drives the incremental LiveView shell (live unread badges, the
// notifications/messages pages, presence). The CSRF token is rendered into the
// root layout's <meta name="csrf-token"> and read via csrfToken() from ./util.

// Rewrites a <time datetime="…Z"> into the viewer's locale and timezone.
// Server-rendered timestamps are UTC; this runs as the LocalTime hook inside
// LiveViews and as a DOMContentLoaded sweep over time[data-localtime] on
// classic controller pages (post cards render on both kinds of page).
//
// data-localtime="second" asks for seconds in the rewritten text. Minutes are
// right for "when did this arrive"; the account-activity log (issue #1087) is
// where they are not — pinning a change down to the second is the whole point
// of that page, and "short" silently drops them.
function localizeTime(el) {
  const dt = new Date(el.dateTime)
  if (!isNaN(dt)) {
    const seconds = el.dataset.localtime === "second"
    el.textContent = new Intl.DateTimeFormat(undefined, {
      dateStyle: "short",
      timeStyle: seconds ? "medium" : "short",
    }).format(dt)
  }
}

onReady(() =>
  document.querySelectorAll("time[data-localtime]").forEach(localizeTime)
)

// The post permalink renders the whole conversation (issue #1006). When the
// permalinked post has thread context above it, jump it into view on arrival —
// its wrapper carries data-thread-scroll plus scroll-mt for the sticky bar.
onReady(() => {
  const focus = document.querySelector("[data-thread-scroll]")
  if (focus) focus.scrollIntoView()
})

// Feed/profile post previews ship the whole body and clamp it to a few lines
// via CSS. Reveal the "Read more" affordance only when the body is really cut —
// i.e. the clamped body overflows, which the server can't know since wrapping is
// width- and font-dependent. A clamped element hides content exactly when its
// full content height (scrollHeight) is taller than its painted box
// (clientHeight); the +1 absorbs sub-pixel rounding.
//
// Both the bottom fade (a mask on [data-clamp-body]) and the control are shown
// or hidden purely by this `is-clamped` class on the WRAPPER (see the
// .post-preview rules in components.css) — the control carries no competing
// `hidden`/`inline-block` display utilities, so the cascade conflict that made
// "Read more" appear on every post (issue #880) is structurally gone. Once the
// reader has expanded a preview (`is-expanded`) we leave it alone: a later
// resize/font sweep must not re-clamp it out from under them.
function revealPreviewClamp(el) {
  if (el.classList.contains("is-expanded")) return
  const body = el.querySelector("[data-clamp-body]")
  if (!body) return
  // A body nothing is painting cannot be measured: both heights read 0, and the
  // answer would come out as "nothing is cut". The fediverse account
  // description hits this every time it is open, since the clamped copy is
  // `group-open:hidden` while the full one shows.
  if (body.clientHeight === 0) return
  const clipped = body.scrollHeight > body.clientHeight + 1
  // "We have looked", which is a different thing from "nothing is cut" — an
  // element that was never measured (no JavaScript, or not yet run) must keep
  // whatever the server rendered rather than be treated as uncut.
  el.classList.add("is-measured")
  el.classList.toggle("is-clamped", clipped)
}

// Expand / collapse a clamped preview in place (the whole body is always in the
// DOM). We animate the body's height between its clamped and full heights: measure both
// around the class flip (getBoundingClientRect forces a sync reflow), then
// transition from start to end and clear the inline overrides once it settles.
// prefers-reduced-motion skips the animation and just flips the state.
function togglePreviewExpand(preview, btn) {
  const body = preview.querySelector("[data-clamp-body]")
  if (!body) return

  const expanding = !preview.classList.contains("is-expanded")

  // Retarget the button's label + aria to the state we're moving to.
  btn.setAttribute("aria-expanded", expanding ? "true" : "false")
  const more = btn.dataset.labelMore
  const less = btn.dataset.labelLess
  if (more && less) btn.textContent = expanding ? less : more

  const flip = () => {
    preview.classList.toggle("is-expanded", expanding)
    preview.classList.toggle("is-clamped", !expanding)
  }

  if (reducedMotion()) {
    flip()
    return
  }

  const startHeight = body.getBoundingClientRect().height
  flip()
  const endHeight = body.getBoundingClientRect().height

  // Nothing to animate (heights equal) — leave the resting state as flip() set it.
  if (Math.abs(endHeight - startHeight) < 1) return

  body.style.overflow = "hidden"
  body.style.height = `${startHeight}px`
  void body.offsetHeight // force a reflow so the start height paints first
  body.style.transition = "height 250ms ease"
  body.style.height = `${endHeight}px`

  const cleanup = () => {
    body.style.transition = ""
    body.style.height = ""
    body.style.overflow = ""
    body.removeEventListener("transitionend", cleanup)
  }
  body.addEventListener("transitionend", cleanup)
  // Backstop in case transitionend never fires (e.g. the tab was hidden).
  setTimeout(cleanup, 400)
}

// One delegated listener drives every expand button — live or dead page, and it
// survives LiveView stream re-renders (the button is never re-bound).
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-post-expand]")
  if (!btn) return
  e.preventDefault()
  const preview = btn.closest("[data-post-preview]")
  if (preview) togglePreviewExpand(preview, btn)
})

// Sweep every preview on the page (classic pages, and the initial static render
// of live pages). The PostPreviewClamp hook re-checks each one on stream patches;
// a debounced resize sweep catches reflows that change how many lines wrap.
// Everything on the page that clamps text by line count and needs to know
// whether it really cut any: the post previews, and the fediverse account
// description, which hides its own expand toggle when there is nothing behind
// it (issue #1268).
const CLAMP_PROBES = "[data-post-preview], [data-remote-summary]"

function sweepPreviewClamps() {
  document.querySelectorAll(CLAMP_PROBES).forEach(revealPreviewClamp)
}

onReady(sweepPreviewClamps)

// A late web-font swap (FOUT) reflows the text and changes how many lines wrap,
// so re-measure once fonts are ready: a card first measured with the wider
// fallback font can otherwise keep a "Read more" link the final font makes
// needless. Cards that stream in later mount post-font, so their hook handles it.
if (document.fonts && document.fonts.ready) {
  document.fonts.ready.then(sweepPreviewClamps)
}

let previewClampResizeTimer
window.addEventListener("resize", () => {
  clearTimeout(previewClampResizeTimer)
  previewClampResizeTimer = setTimeout(sweepPreviewClamps, 150)
})

// A <details> that opens is the one reflow nothing above catches: a shut lid
// paints nothing, so revealPreviewClamp bails on its zero-height body and the
// clamped text behind it would sit cut with no "Read more" to open it. Toggle
// does not bubble, hence the capture phase.
//
// Only the lid that moved can have gone from unpaintable to paintable, so this
// measures its own subtree and NOT the page: nearly every <details> in the app
// clamps nothing (a ⋯ menu on each of twenty feed cards, the sensitive-image
// lid, the tag timeline's filter panel), and each of those opening or closing
// would otherwise force a layout read on every preview in the document. There
// is deliberately no `if (!el.open) return`: a CLOSING [data-remote-summary] is
// exactly when its clamped copy becomes measurable again.
document.addEventListener(
  "toggle",
  (e) => {
    const el = e.target
    if (!(el instanceof Element)) return
    if (el.matches(CLAMP_PROBES)) revealPreviewClamp(el)
    el.querySelectorAll(CLAMP_PROBES).forEach(revealPreviewClamp)
  },
  true
)

// Quote a passage into a reply (issue #1114). Mark part of a post, press that
// post's Reply control, and the reply page opens with the marked text already
// in the composer as a blockquote. No new chrome: the selection rides along on
// the Reply link the card already has, as a `quote` query parameter that
// VutuvWeb.Markdown.blockquote/1 normalizes and caps server-side.
//
// The server marks the two halves — `data-post-body` on a post's prose, and
// `data-quote-reply` on the enclosing card naming its Reply control. Thread
// cards nest, so resolving the card from the SELECTION (innermost marked
// ancestor) rather than from the link is what keeps a marked reply from
// quoting itself into its parent's answer.
const QUOTE_MAX = 500

// What was selected when the pointer went down. The browser collapses a
// selection as part of the default action of pointerdown, i.e. before the
// link's click event ever fires, so by click time it is already gone.
let pendingQuote = null

function selectionQuote() {
  const selection = window.getSelection()
  if (!selection || selection.isCollapsed) return null

  const text = selection.toString().trim()
  if (!text) return null

  const anchor = selection.anchorNode
  const start = anchor && (anchor.nodeType === 1 ? anchor : anchor.parentElement)
  const body = start && start.closest("[data-post-body]")
  const card = body && body.closest("[data-quote-reply]")
  if (!card) return null

  return { text: text.slice(0, QUOTE_MAX), replyId: card.dataset.quoteReply }
}

// Capture, so a handler that stops propagation can't rob us of the selection.
document.addEventListener(
  "pointerdown",
  () => {
    pendingQuote = selectionQuote()
  },
  true
)

document.addEventListener(
  "click",
  (e) => {
    // A keyboard activation fires no pointerdown and leaves the selection
    // standing, so the live selection is tried first and the remembered one is
    // the fallback for the mouse/touch path.
    const quote = selectionQuote() || pendingQuote
    pendingQuote = null
    if (!quote) return

    const link = e.target.closest("a[href]")
    if (!link || link.id !== quote.replyId) return

    const href = link.getAttribute("href")
    const url = new URL(href, window.location.origin)
    url.searchParams.set("quote", quote.text)
    link.setAttribute("href", url.pathname + url.search)
    // Put the plain href back once the navigation is under way: a click the
    // browser does not follow (opening in a new tab) would otherwise leave this
    // card's Reply link pointing at a stale quote.
    setTimeout(() => link.setAttribute("href", href), 0)
  },
  true
)

// The four lifecycle names LiveView calls on a hook. Everything else on the
// loaded implementation is a helper it calls as `this.something()`, so the
// helpers have to land on the hook INSTANCE, not stay on the module export.
const EDITOR_LIFECYCLE = ["mounted", "beforeUpdate", "updated", "destroyed"]

// Loads the editor bundle once per page and hands back its module namespace.
// Cached as a promise, not as a result: several composers can mount in the same
// patch (a message thread beside the post composer) and they must share one
// request, including while it is still in flight.
//
// A failed load drops out of the cache, so the next composer to mount tries
// again. This bundle is the one request on the page big enough for a bad link
// to drop, and remembering that failure would leave the member with a plain
// textarea until they reload — the opposite of what the split is for.
let editorModule = null
function loadEditor(src) {
  editorModule ||= import(src).catch((err) => {
    editorModule = null
    throw err
  })
  return editorModule
}

// Stand-in for the real MarkdownEditor hook while its bundle is still being
// fetched. It cannot simply forward calls, because the implementation's
// lifecycle methods reach for helpers (`this.applyState()`, `this.fenceLabels()`
// …) that live on the same object — so on arrival we copy every helper onto
// this instance and only then run the real `mounted()`.
//
// The three later callbacks stay proxied rather than copied so that this object
// remains the authority on ordering: each one is a no-op until the bundle
// lands, which is correct in every case. Before the editor exists there is no
// manual resize to remember (beforeUpdate), no prose to re-seed (updated), and
// nothing to tear down (destroyed) — and `destroyed` additionally has to be able
// to cancel a boot that is still in flight, or the implementation would mount
// itself onto an element LiveView has already removed.
const MarkdownEditor = {
  // The bundle is 512 kB of ProseMirror (137 kB over the wire), and it used to
  // be fetched, parsed and run from `mounted()` on every page carrying a
  // composer — including /feed, where the composer is collapsed. The panel
  // stays mounted so a half-typed draft survives a re-render (#1148) and so
  // morphdom never re-parents the editor mid-sentence (#1200), and LiveView
  // mounts hooks on hidden elements all the same, so a feed visit ran the whole
  // editor for a composer nobody had opened: measured at t=1.6s on an ordinary
  // load (2026-08-31), competing with the first paint and the socket connect.
  //
  // So the boot asks one question, synchronously, at mount: **is this editor
  // what the page is for?** A message thread, the organization form and the job
  // form render it visible, and those boot exactly as they always did. The
  // feed's collapsed composer is the only one that is not, and it waits for the
  // browser to be idle — off the critical path, but still long before anybody
  // presses "Write a post", so opening the composer is no slower than before.
  //
  // Deliberately NOT an IntersectionObserver, which is the obvious tool and the
  // wrong one: it delivers nothing at all while a tab is in the background, so
  // a feed opened in a background tab would sit on the plain textarea until the
  // tab was focused (measured 2026-08-31). Idle callbacks have no such rule.
  //
  // On a metered connection nothing speculative runs and the first reach for
  // the composer pays for it; the plain textarea underneath is a working
  // composer until it lands.
  mounted() {
    const src = this.el.dataset.mdeSrc
    if (!src) return

    // No client rects = `display: none` on it or on something above it.
    if (this.el.getClientRects().length > 0) {
      this.boot_(src)
      return
    }

    this.onReach_ = () => this.boot_(src)
    this.el.addEventListener("focusin", this.onReach_)
    this.el.addEventListener("pointerdown", this.onReach_)

    if (!savesData()) this.warm_ = whenIdle(() => this.boot_(src))
  },

  // Fetch, adopt and run the real hook. Idempotent: a reach and the idle
  // warm-up can both arrive, and either may already have the module in hand.
  boot_(src) {
    if (this.booted_) return
    this.booted_ = true
    this.stopWaiting_()

    loadEditor(src)
      .then(({ MarkdownEditor: impl }) => {
        if (this.destroyed_) return
        for (const key of Object.keys(impl)) {
          if (!EDITOR_LIFECYCLE.includes(key)) this[key] = impl[key]
        }
        this.impl_ = impl
        return impl.mounted.call(this)
      })
      .catch((err) => {
        // The plain textarea underneath is a working composer without any of
        // this (the no-JS fallback markdown_editor.js is built around), so a
        // failed fetch degrades instead of breaking. Log it: silently serving
        // the fallback is exactly the kind of thing nobody notices for weeks.
        console.error("[mde] editor bundle failed to load", err)
      })
  },

  beforeUpdate() {
    this.impl_?.beforeUpdate.call(this)
  },

  updated() {
    this.impl_?.updated.call(this)
  },

  destroyed() {
    this.destroyed_ = true
    this.stopWaiting_()
    this.impl_?.destroyed.call(this)
  },

  // Everything that was only there to notice the composer being reached.
  stopWaiting_() {
    cancelIdle(this.warm_)
    if (!this.onReach_) return
    this.el.removeEventListener("focusin", this.onReach_)
    this.el.removeEventListener("pointerdown", this.onReach_)
    this.onReach_ = null
  },
}

// Hooks. MarkdownEditor is the Milkdown WYSIWYG composer (posts + messages),
// loaded on demand by the proxy above.
// TagInput is the pill box on every tag field (see the sweep below, which
// serves the same component on classic pages). LocalTime localizes timestamps
// (see above). ScrollBottom follows a chat thread's newest message.
// Browser notifications (issue #1249). Shared by the `WebNotify` hook (the
// prompt in the shell) and the card on /settings/notifications, because both
// answer the same question about the same browser.
//
// The account stores whether the member wants notifications; only the browser
// knows whether it will actually show one, and that answer belongs to one
// browser profile - which is why a member who switches the feature on at their
// desk still has to say yes on their laptop.
//
// `Notification.permission` is "default" (never asked), "granted" or "denied";
// a browser with no Notifications API at all is a fourth case, and reading it
// as "denied" would tell somebody to go fix a browser setting that does not
// exist.
const NOTIFY_PROMPT_KEY = "vutuv:notify-prompt-dismissed"

function notifyPermission() {
  return "Notification" in window ? Notification.permission : "unsupported"
}

// Through util.js's guarded store: a private window, or a browser set to block
// site data, throws on plain access. Forgetting a dismissal simply offers the
// prompt again, which is the right way to fail.
function notifyPromptDismissed() {
  return localGet(NOTIFY_PROMPT_KEY) === "1"
}

function setNotifyPromptDismissed(dismissed) {
  localSet(NOTIFY_PROMPT_KEY, dismissed ? "1" : null)
}

// Must run inside a real click: Firefox and Safari refuse the request without
// a user gesture, and Chrome quietly downgrades a page-load prompt. Whatever
// the answer - including a refusal, and including a browser with no API at all
// - it ends in one `vutuv:notify-permission` event, which is how both the
// prompt and the settings card re-read the state without knowing about each
// other. Both the promise and the legacy callback form are handled.
// It also RESOLVES on that one event, so a caller that has to wait for the
// answer (the per-device push switch) awaits this rather than listening for the
// event itself - a rendezvous any other dispatcher of the event could satisfy.
function requestNotifyPermission() {
  return new Promise((resolve) => {
    let done = false
    const finish = () => {
      if (done) return
      done = true
      window.dispatchEvent(new CustomEvent("vutuv:notify-permission"))
      resolve()
    }

    if (!("Notification" in window)) return finish()

    try {
      const result = Notification.requestPermission(finish)
      if (result && typeof result.then === "function") result.then(finish, finish)
    } catch (_e) {
      finish()
    }
  })
}

// One delegated listener for both surfaces: the shell's prompt bar and the
// settings card offer the same button, and neither needs its own copy.
document.addEventListener("click", (event) => {
  if (event.target.closest("[data-notify-allow]")) requestNotifyPermission()
})

// -- Service worker and Web Push (issue #1729) -----------------------------
//
// What the section above does works only while a vutuv page is open: a
// `Notification` raised by a tab dies with the tab. Waking a phone whose app is
// closed needs a service worker, and this is where it is registered, kept up to
// date, and asked for a push subscription.
//
// The worker itself is /sw.js (served by VutuvWeb.ServiceWorkerController from
// assets/js/sw.js) and it is not part of this bundle: a worker controls only
// the directory it is served from, so it has to sit at the root.
//
// The shell's #web-notify element carries the two things this needs from the
// server - who is signed in here, and this installation's VAPID public key -
// because it is on every page for every logged-in member and is where the
// permission prompt already lives.
const PUSH_OWNER_KEY = "vutuv:push-owner"

function shellNotifyEl() {
  return document.getElementById("web-notify")
}

function pushMember() {
  return shellNotifyEl()?.dataset.member || null
}

function vapidKey() {
  return shellNotifyEl()?.dataset.vapidKey || null
}

// One registration per page, shared by everything below. It is deliberately
// unconditional: the asset cache and the offline page are worth having for a
// logged-out visitor too, and a failure (an unsupported browser, an insecure
// origin, a member who blocked site data) resolves to null rather than
// throwing into an unrelated feature.
let swRegistration = null

function serviceWorker() {
  if (!("serviceWorker" in navigator)) return Promise.resolve(null)
  if (swRegistration) return swRegistration

  swRegistration = navigator.serviceWorker.register("/sw.js").catch(() => null)

  return swRegistration
}

// "Reload" on the shell's update bar (issue #1729). WHETHER to offer it is the
// server's answer - it is the only side that knows which release this document
// came from - so all that is left here is carrying it out. Delegated at the
// document, so it survives the patches that re-render the bar.
//
// **The control is an `<a href>` to the current page, and that is load-bearing
// rather than tidiness.** The bar renders ONLY into a document running the
// PREVIOUS release, so the handler that answers its click is the previous
// release's, never this one. That handler posts `skip-waiting` to a waiting
// worker and does nothing whatsoever when none is waiting - which is the common
// case for exactly this reader, because a tab open across a deploy never
// navigates and so never triggers the browser's own worker check. It does not
// call `preventDefault` either, so the link's own navigation still carries them
// to the new release. Without the href, the bar's primary control is dead for
// most of the cohort it is shown to on the deploy that ships it. It also makes
// the control work with no JavaScript at all.
document.addEventListener("click", async (event) => {
  if (!event.target.closest("[data-sw-reload]")) return

  // Synchronously, before any await: one await later the browser has already
  // followed the link and this handler is addressing a page that is leaving.
  event.preventDefault()

  // `reload()` rather than the href, which is the path without its query: once
  // we are in JS the current URL is the better target.
  const reload = () => window.location.reload()
  const waiting = (await serviceWorker())?.waiting

  // No worker waiting is the ordinary case, not a failure: the document is
  // stale while the worker is not (it updates on its own schedule, which is not
  // the deploy's), and then a plain reload is the whole errand.
  if (!waiting) return reload()

  // The waiting worker takes over only when it is asked to, and the page
  // reloads only once it has - promoting it unasked would swap the assets
  // under a half-written post. If it never answers, go anyway after a moment:
  // a control that visibly did nothing is worse than one that reloads twice.
  const timer = setTimeout(reload, 2000)
  navigator.serviceWorker.addEventListener(
    "controllerchange",
    () => {
      clearTimeout(timer)
      reload()
    },
    { once: true }
  )
  waiting.postMessage({ type: "skip-waiting" })
})

async function currentPushSubscription() {
  const registration = await serviceWorker()
  if (!registration || !("PushManager" in window)) return null
  return registration.pushManager.getSubscription()
}

// Registers this browser. Everything it needs can be missing for an ordinary
// reason - an unsupported browser, a member who said no, an installation with
// push switched off - so each of them answers false rather than throwing.
async function subscribeToPush() {
  const registration = await serviceWorker()
  const key = vapidKey()
  if (!registration || !key || !("PushManager" in window)) return false
  if (notifyPermission() !== "granted") return false

  try {
    const subscription =
      (await registration.pushManager.getSubscription()) ||
      (await registration.pushManager.subscribe({
        // Required by Chrome, and true of us: every push we send draws
        // something the member can see.
        userVisibleOnly: true,
        // base64url text on the wire, bytes in the API - `b64urlToBuf`
        // from util.js, the same decoder the passkey ceremony uses.
        applicationServerKey: b64urlToBuf(key),
      }))

    // The browser's own `PushSubscription` JSON, posted verbatim: one shape,
    // defined by the web platform, with nothing to keep in step on two sides.
    const answer = await postJSON("/settings/push_devices", subscription.toJSON())
    if (!answer.ok) return false

    localSet(PUSH_OWNER_KEY, pushMember())
    return true
  } catch (_e) {
    return false
  }
}

// Forgets this browser, at the push service AND here. The local
// `unsubscribe()` is the half that matters: it invalidates the endpoint, so
// even a server call that never lands leaves a subscription the next push
// answers 410 for, which deletes the row.
async function unsubscribeFromPush() {
  const subscription = await currentPushSubscription()
  localSet(PUSH_OWNER_KEY, null)
  if (!subscription) return

  try {
    await request("/settings/push_devices", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ endpoint: subscription.endpoint }),
    })
  } catch (_e) {
    // Offline, or signed out already; the unsubscribe below still stands.
  }

  try {
    await subscription.unsubscribe()
  } catch (_e) {}
}

// A subscription belongs to a browser, not to an account, so signing out - or
// signing in as somebody else on the same phone - has to end the old one.
// Without this, a device somebody handed back keeps being woken for the member
// who used it last.
//
// **A missing #web-notify means "signed out" only where the shell is on the
// page at all.** It is equally missing on every page rendered with the app
// layout dropped - the outbound hand-off page is one (`chrome_for/2` in
// ControllerHelpers), and the root layout still loads this bundle there - so
// reading its absence as a sign-out would revoke a member's subscription for
// the crime of clicking a link that leaves the site. `#app-shell` is what
// ShellLive renders for everybody, logged in or out, so it tells the two
// cases apart; with no shell we simply do not know, and do nothing.
async function reconcilePushOwner() {
  if (!document.getElementById("app-shell")) return

  const owner = localGet(PUSH_OWNER_KEY)
  if (!owner || owner === pushMember()) return
  await unsubscribeFromPush()
}

onReady(() => {
  serviceWorker().then(() => reconcilePushOwner())
})

// The per-device switch on /settings/notifications: "also when vutuv is
// closed". Per device because the subscription is, which is why it is not one
// of the account's checkboxes and never reaches a changeset - the answer IS
// the row, written from here.
function wirePushDeviceToggle(box) {
  if (!once(box, "pushDevice")) return

  currentPushSubscription().then((subscription) => {
    box.checked = !!subscription
    box.disabled = false
  })

  box.addEventListener("change", async () => {
    box.disabled = true

    if (box.checked) {
      // Inside the change event, which is a real user gesture - Safari and
      // Firefox refuse `requestPermission()` without one, and on an iPhone
      // this is the only path to a notification at all.
      if (notifyPermission() === "default") await requestNotifyPermission()
      box.checked = await subscribeToPush()
    } else {
      await unsubscribeFromPush()
    }

    box.disabled = false
    window.dispatchEvent(new CustomEvent("vutuv:notify-permission"))
  })
}

onReady(() => document.querySelectorAll("[data-push-device]").forEach(wirePushDeviceToggle))

// The browser tab's teaser (issue #1681) has a twist the other examples do
// not: its stage is the tab this settings page is sitting in,
// so the example can simply BE the thing, played in the real tab title through
// the real hook. Nothing here animates anything — it hands the frames to
// TabBadge, which owns document.title and would otherwise put the marker back
// over whatever this wrote.
document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-tab-teaser-play]")
  if (!button) return

  // Read from the document rather than from an enclosing card: the kit's
  // <.card> is a pile of utility classes and emits no `card` class to climb to.
  const on = document.querySelector('input[type="checkbox"][name*="browser_tab_teaser"]')?.checked
  if (!on) return

  let frames = []
  try {
    frames = JSON.parse(button.dataset.frames || "[]")
  } catch (_error) {
    return
  }

  window.dispatchEvent(new CustomEvent("vutuv:tab-teaser", { detail: { frames: frames } }))
})

// Keeps /feed's address bar in step with the calendar, so the day on screen is
// the day a copied link reopens.
//
// The feed LiveView is `live_render`ed by the controller that owns the
// agent-format siblings rather than routed, so it has no `push_patch/2` and
// this is the only way it can touch the URL. `replaceState`, never `pushState`:
// a reader stepping through a fortnight of days would otherwise have to press
// Back fourteen times to leave the feed.
const FeedUrl = {
  mounted() {
    this.handleEvent("feed:url", ({ query }) => {
      const url = query ? `${location.pathname}?${query}` : location.pathname

      if (url !== location.pathname + location.search) {
        history.replaceState(history.state, "", url)
      }
    })
  },
}

// How long a revealed card has to stand still in view before its unread dot
// comes off, and how long the fade is given before the attribute goes. The
// second has to outlast the `[data-new-mark]::before` transition in app.css
// (260ms). A `transitionend` would remove the duplicate number, but
// `prefers-reduced-motion` sets `transition: none` and then it never fires.
const NEW_MARK_SEEN_MS = 1500
const NEW_MARK_FADE_MS = 300

// The unread dots on the rows the feed's "new posts" pill just revealed, and
// the only thing that takes them off again. `reveal_pending/0` stamps
// `data-new-mark` on those rows; this decides when the reader has looked at one.
//
// **An IntersectionObserver here where `MarkdownEditor` above turns one down**,
// and for the same measured reason read the other way round: it reports nothing
// at all while the tab is in the background. That was wrong for a boot that has
// to finish anyway, and it is exactly right for a mark meaning "unread" —
// nothing is being read in a background tab, so nothing there should stop being
// unread.
//
// Safe to ship as a new hook: an old bundle logs one "unknown hook" line and
// carries on, and it holds the old stylesheet too, which has no rule for the
// dot — so such a tab draws nothing rather than something broken.
const NewMarks = {
  mounted() {
    this.holds = new Map()

    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          // Scrolled clean past upwards counts as looked at, however briefly it
          // was in view: the reader has moved on, and a dot they can no longer
          // reach is a mark nobody can act on.
          if (entry.boundingClientRect.bottom < 0) {
            this.clearMark(entry.target)
          } else if (entry.intersectionRatio >= 0.6) {
            this.hold(entry.target)
          } else {
            this.releaseHold(entry.target)
          }
        }
      },
      { threshold: [0, 0.6] },
    )

    // The pill is NOT inside this element — it sits on the compose line above —
    // so the listener goes on the document, the way the rest of this file does
    // its delegation. A frame later, because the JS command that stamps the
    // marks runs in this same click and the order between the two is not ours
    // to decide.
    //
    // `updated()` cannot replace this and is deliberately not implemented: the
    // reveal happens entirely in the browser, and a stream sends no patch for
    // rows it has already handed over, so LiveView has nothing to call back
    // about. A row the server DOES re-render (a photo scan, a translation, the
    // midnight restream) comes back without its mark, which is the accepted
    // price of a marker the server never renders.
    this.onPillClick = (event) => {
      if (event.target.closest("#show-new-posts")) {
        requestAnimationFrame(() => this.sweepMarks())
      }
    }

    document.addEventListener("click", this.onPillClick)
  },

  sweepMarks() {
    for (const row of this.el.querySelectorAll(':scope > [data-new-mark="1"]')) {
      this.observer.observe(row)
    }
  },

  hold(row) {
    if (this.holds.has(row)) return

    this.holds.set(
      row,
      setTimeout(() => this.clearMark(row), NEW_MARK_SEEN_MS),
    )
  },

  releaseHold(row) {
    const timer = this.holds.get(row)

    if (timer) {
      clearTimeout(timer)
      this.holds.delete(row)
    }
  },

  // Two steps, because the dot fades: the attribute has to keep matching the
  // CSS long enough for the transition to run, and only then come off.
  clearMark(row) {
    this.releaseHold(row)
    this.observer.unobserve(row)

    if (row.dataset.newMark !== "1") return

    row.dataset.newMark = "seen"
    setTimeout(() => row.removeAttribute("data-new-mark"), NEW_MARK_FADE_MS)
  },

  destroyed() {
    document.removeEventListener("click", this.onPillClick)
    // A hold still running keeps its row alive through the closure and would
    // fire on a node that has left the document.
    for (const timer of this.holds.values()) clearTimeout(timer)
    this.observer.disconnect()
  },
}

const Hooks = {
  MarkdownEditor,
  TagInput,
  FeedUrl,
  NewMarks,
  LocalTime: {
    mounted() {
      localizeTime(this.el)
    },
    updated() {
      localizeTime(this.el)
    },
  },
  // Post-preview clamp (see revealPreviewClamp above): reveal the "Read more"
  // link when the six-line-clamped body overflows. Re-checks on every stream
  // patch so a re-rendered card measures again.
  PostPreviewClamp: {
    mounted() {
      revealPreviewClamp(this.el)
    },
    updated() {
      revealPreviewClamp(this.el)
    },
  },
  // A chat thread follows its newest message — but only for a reader who is
  // sitting at the bottom of it. Every keystroke in the composer runs
  // phx-change ("typing") and every patch morphs this container, so an
  // unconditional scrollTop = scrollHeight yanked the thread down on each
  // letter: answering a message you had scrolled up to read was impossible.
  //
  // The position must be remembered from OUTSIDE the patch. Reading it in
  // beforeUpdate looks right and is not: while LiveView re-orders a stream's
  // children (which is how "Load older messages" prepends its page), the
  // container's own numbers are momentarily clamped to the top, so a delta
  // taken there lands the reader a screen too high. Scroll events, in
  // contrast, are dispatched between frames and never mid-patch — so remember()
  // runs on every scroll (our own writes included) and always sees settled
  // geometry.
  //
  // What is remembered is the first bubble's offset inside the visible box,
  // not a scroll height: only growth ABOVE the viewport may move scrollTop,
  // while a new message arriving below must leave the reader where they are.
  // Sending is the exception — the server pushes "chat:sent" so your own
  // message still takes you along.
  ScrollBottom: {
    mounted() {
      this.toBottom()
      this.remember()
      this.el.addEventListener("scroll", () => this.remember(), { passive: true })
      // The scroll event our own toBottom() causes only arrives at the next
      // frame, and the echo's patch beats it, so pin synchronously here.
      this.handleEvent("chat:sent", () => {
        this.pinned = true
        this.toBottom()
      })
    },
    updated() {
      if (this.pinned) return this.toBottom()
      const anchor = this.anchorId && document.getElementById(this.anchorId)
      if (anchor) this.el.scrollTop += this.relOf(anchor) - this.anchorRel
    },
    remember() {
      this.pinned = this.atBottom()
      // A pinned thread never reads the anchor, and sitting at the bottom is
      // the common case, so don't measure one — the scroll event that ends the
      // pin records it.
      if (this.pinned) return
      const anchor = this.el.firstElementChild
      this.anchorId = anchor && anchor.id
      this.anchorRel = this.relOf(anchor)
    },
    toBottom() {
      this.el.scrollTop = this.el.scrollHeight
    },
    // How far a bubble sits below the top of the visible box. Painted
    // rectangles rather than offsetTop, so the reading stays right whatever
    // the browser's own scroll anchoring did during the patch.
    relOf(el) {
      return el ? el.getBoundingClientRect().top - this.el.getBoundingClientRect().top : 0
    },
    // A few pixels of slack: sub-pixel layout leaves "the bottom" a hair short
    // of the exact number, and a reader that close is still reading along.
    atBottom() {
      return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
    },
  },
  // Browser-tab title indicator, so a backgrounded tab still shows new activity.
  // ShellLive pushes the state; this hook prefixes document.title:
  //   "(3) vutuv"   unread messages + notifications (exact; shown always)
  //   "•(3) vutuv"  plus new feed posts that arrived while the tab was hidden
  //   "• vutuv"     only new feed posts, nothing unread
  // The feed dot is intentionally gated on document.hidden (feed posts have no
  // read state) and cleared the moment the member returns to the tab. LiveView's
  // <.live_title> rewrites the title on navigation, which would drop our prefix,
  // so a MutationObserver on <title> watches for a title this hook did not
  // write, takes it as the new base and re-applies the marker on top; comparing
  // against our own last write is what keeps that from looping.
  //
  // For a few seconds the title also says WHAT arrived (issue #1681): the
  // author and the first words, paged through the tab one frame per second and
  // then handed back to the page's own title. Frames rather than a scroll, and
  // only a few of them, because a hidden tab is where the browser owns the
  // clock in the strongest sense — timers there are clamped to roughly one per
  // second, and Chrome drops a chained timer to one per MINUTE once the page
  // has been hidden for five minutes ("intensive throttling"), which is exactly
  // the tab this is for. So whatever stands last has to be a line that is still
  // true a minute later, and the animation stops rather than looping.
  //
  // The second asked for below is a floor, not a promise: a hidden tab aligns
  // timer wake-ups to whole seconds, so a timeout re-armed just after one
  // misses the next boundary and each frame really stands about two seconds
  // (measured in headless Chrome 151; the visible settings example runs at the
  // requested one). ShellLive's window is sized in the measured figure, since
  // it decides whether a second arrival still reaches a running animation.
  TabBadge: {
    mounted() {
      this.unread = 0
      this.feedPending = false
      this.teaser = null
      this.teaserText = null
      this.baseTitle = this.strip(document.title)

      this.handleEvent("tab:badge", ({ unread }) => {
        this.unread = unread || 0
        this.apply()
      })

      // A new feed post only earns the dot when the member isn't looking here.
      this.handleEvent("tab:new_post", () => {
        if (document.hidden && !this.feedPending) {
          this.feedPending = true
          this.apply()
        }
      })

      this.handleEvent("tab:teaser", ({ id, frames }) => this.startTeaser(id, frames))

      // "Play the example" on /settings/preferences. The member is plainly
      // looking at this tab, which is the one case the hidden-gate below has to
      // give way for — the same exemption the test notification takes.
      this.onPreview = (event) => this.startTeaser(0, event.detail.frames, true)
      window.addEventListener("vutuv:tab-teaser", this.onPreview)

      // From the second arrival inside one window the server sends a count
      // instead of a second quote; it becomes the teaser's closing frame.
      this.handleEvent("tab:teaser_more", ({ id, text }) => {
        if (this.teaser && this.teaser.id === id) this.teaser.more = text
      })

      // Returning to the tab clears the feed dot and takes the teaser with it:
      // a title paging through somebody's post while the member is reading the
      // page is noise, and the page they are on already shows the arrival.
      this.onVisibility = () => {
        if (!document.hidden) {
          this.feedPending = false
          this.stopTeaser()
        }
        this.reportVisibility()
      }
      document.addEventListener("visibilitychange", this.onVisibility)

      const titleEl = document.querySelector("title")
      if (titleEl) {
        this.observer = new MutationObserver(() => {
          // Our own writes come back through here too. Anything else is the
          // page changing its own title (a live navigation), which is the new
          // base the marker and the teaser sit on top of.
          if (document.title === this.lastWritten) return
          this.baseTitle = this.strip(document.title)
          this.apply()
        })
        this.observer.observe(titleEl, {
          childList: true,
          characterData: true,
          subtree: true,
        })
      }

      // The server refuses to spend a feed lookup on a tab that has not said it
      // is in the background, so this is what turns the teaser on at all.
      this.reportVisibility()
      this.apply()
    },
    // A rejoin runs ShellLive's `mount/3` again, and a fresh mount starts
    // `tab_hidden?` at **false** — the socket has no memory of what this tab
    // said before it dropped. Nothing here volunteers the answer twice on its
    // own: `mounted()` runs once (the element survives the patch) and a tab
    // hidden throughout fires no `visibilitychange`. So without this the server
    // takes every reconnected background tab for one being read and spends
    // nothing on it, for good — and since a deploy, a laptop waking or any
    // network blip reconnects the socket, that is the normal state of a
    // long-lived tab, not an edge case. The dot kept working the whole time
    // (pushed unconditionally, gated in the browser), which is why the feature
    // read as simply broken while every test stayed green.
    reconnected() {
      this.reportVisibility()
    },
    reportVisibility() {
      this.pushEvent("tab:visibility", { hidden: document.hidden })
    },
    // The indicator string: "•(3) ", "(3) ", "• " or "" when nothing is new.
    prefix() {
      const dot = this.feedPending ? "•" : ""
      const num = this.unread > 0 ? `(${this.unread})` : ""
      const marker = dot + num
      return marker ? `${marker} ` : ""
    },
    strip(title) {
      return title.replace(/^\s*•?\s*(\(\d+\)\s*)?/, "")
    },
    startTeaser(id, frames, preview) {
      if ((!document.hidden && !preview) || !frames || frames.length === 0) return

      this.stopTeaser()
      this.teaser = { id: id, frames: frames, index: 0, more: null }
      this.teaserStep()
    },
    teaserStep() {
      const teaser = this.teaser
      if (!teaser) return

      if (teaser.index < teaser.frames.length) {
        this.teaserText = teaser.frames[teaser.index]
        teaser.index += 1
      } else if (teaser.more) {
        this.teaserText = teaser.more
        teaser.more = null
      } else {
        this.stopTeaser()
        return
      }

      this.apply()
      this.teaserTimer = setTimeout(() => this.teaserStep(), 1000)
    },
    stopTeaser() {
      if (this.teaserTimer) clearTimeout(this.teaserTimer)
      this.teaserTimer = null
      this.teaser = null
      this.teaserText = null
      this.apply()
    },
    apply() {
      // The marker always leads; behind it stands either a teaser frame or the
      // page's own title, so a count or a dot can rise, fall or vanish without
      // leaving a stale marker and without losing the title underneath.
      const next = this.prefix() + (this.teaserText || this.baseTitle)
      if (next === document.title) return
      this.lastWritten = next
      document.title = next
    },
    destroyed() {
      document.removeEventListener("visibilitychange", this.onVisibility)
      window.removeEventListener("vutuv:tab-teaser", this.onPreview)
      if (this.teaserTimer) clearTimeout(this.teaserTimer)
      if (this.observer) this.observer.disconnect()
    },
  },
  // Browser notifications (issue #1249): a popup for activity that arrives while
  // the member is not looking at vutuv. ShellLive pushes a finished, translated
  // line as "notify:show" whenever the member switched the feature on; this hook
  // owns the two questions the server cannot answer.
  //
  // (1) Is the member looking at vutuv right now? `document.hidden` alone is too
  // narrow: it is false for a vutuv tab that is frontmost in a window sitting
  // behind the editor somebody is actually working in, which is the case the
  // issue is about. So "away" is hidden OR unfocused.
  //
  // (2) Did THIS browser grant permission? The switch lives on the account and
  // follows the member to every machine; the permission belongs to one browser
  // profile and has to be asked for from a real click - Firefox and Safari
  // refuse `requestPermission()` without a user gesture, so an automatic prompt
  // on page load would be denied outright. Hence the server-rendered prompt
  // inside this element, shown only where the browser has never been asked.
  WebNotify: {
    mounted() {
      this.handleEvent("notify:show", (payload) => this.show(payload))

      // Delegated, so it survives the patches that replace the prompt node.
      // Allow is handled by the document-level listener above, which the
      // settings card shares.
      this.onClick = (event) => {
        if (event.target.closest("[data-notify-dismiss]")) this.dismiss()
      }
      this.el.addEventListener("click", this.onClick)

      this.onPermission = () => this.applyPrompt()
      window.addEventListener("vutuv:notify-permission", this.onPermission)

      // "Send a test notification" on /settings/notifications. That page is a
      // classic controller page with no socket of its own, so it asks through
      // this hook - the same relay the permission event uses - and the round
      // trip is the point: a test raised locally in JS would prove nothing
      // about the path a real notification takes.
      this.onTest = () => this.pushEvent("notify:test", {})
      window.addEventListener("vutuv:notify-test", this.onTest)

      // Read once. `updated()` runs on every shell patch - a people-counter
      // tick, a presence diff, the hourly clock - and this value changes only
      // through dismiss() below.
      this.dismissed = notifyPromptDismissed()
      this.enabled = this.el.dataset.enabled
      this.applyPrompt()
    },
    updated() {
      // Switching the feature back on is a fresh ask: somebody who dismissed
      // the prompt months ago and has now deliberately turned it on again
      // should be offered it, not left with a switch that does nothing here.
      const enabled = this.el.dataset.enabled
      if (enabled === "true" && this.enabled === "false") {
        setNotifyPromptDismissed(false)
        this.dismissed = false
      }
      this.enabled = enabled
      this.applyPrompt()
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick)
      window.removeEventListener("vutuv:notify-permission", this.onPermission)
      window.removeEventListener("vutuv:notify-test", this.onTest)
    },
    // Re-applied on every patch rather than only when something changed: the
    // server re-renders the `hidden` attribute each time, and this is what
    // takes it off again.
    applyPrompt() {
      const prompt = this.el.querySelector("[data-notify-prompt]")
      if (!prompt) return
      prompt.hidden = notifyPermission() !== "default" || this.dismissed
    },
    dismiss() {
      setNotifyPromptDismissed(true)
      this.dismissed = true
      this.applyPrompt()
    },
    show({ tag, title, body, icon, url, test, ack }) {
      if (notifyPermission() !== "granted") return
      // Looking at vutuv means the badge and the bell already said it - except
      // for the test, which the member asked for while plainly looking at the
      // page, and which would otherwise be a button that does nothing.
      if (!test && !document.hidden && document.hasFocus()) return

      let notification
      try {
        notification = new Notification(title, {
          body: body || undefined,
          icon: icon || undefined,
          // One tag per stream, so a burst of ten replaces itself into one
          // popup and four open vutuv tabs raise one between them (the browser
          // collapses same-tag notifications across an origin). A replacement
          // is silent, so only the first of a burst makes a sound - which is
          // the whole reason `renotify` stays off for news.
          //
          // The test is the one case that wants the opposite: pressing it a
          // second time (after turning Do Not Disturb off, say) has to announce
          // itself again, or a silent replacement reads as "still broken".
          tag: `vutuv-${tag}`,
          renotify: !!test,
        })
      } catch (_e) {
        // Some browsers refuse the constructor outright (a service worker is
        // required on Android Chrome). Nothing to do but stay quiet.
        return
      }

      notification.onclick = () => {
        window.focus()
        notification.close()
        this.acknowledge(ack, () => {
          if (url) window.location.href = url
        })
      }

      // Only ever fired for a test: it is what tells the settings card that a
      // popup really was constructed, so the card can stop waiting instead of
      // leaving the member to guess whether anything happened.
      if (test) window.dispatchEvent(new CustomEvent("vutuv:notify-shown"))
    },
    // Clicking a popup means the member has seen that one event, so the bell
    // should drop it and keep the rest. The server needs to hear that BEFORE
    // the tab navigates: assigning `location.href` tears the socket down, and
    // a push in flight would go with it. So navigation waits for the server's
    // reply - and for a socket that is slow or already gone, a short timer
    // takes them to the page anyway. Whichever comes first wins; `done` is
    // what keeps the member from being sent twice.
    acknowledge(ack, then) {
      if (!ack) return then()

      let done = false
      const go = () => {
        if (done) return
        done = true
        then()
      }

      this.pushEvent("notify:seen", ack, go)
      window.setTimeout(go, 700)
    },
  },
  // The admin member browser (VutuvWeb.Admin.UserLive) pages in place over the
  // socket; without this you stay parked at the pager (bottom) after clicking
  // Next/Prev. Scroll the browser card back to the top whenever its page number
  // changes, so each page starts at the top (scroll-mt clears the sticky nav).
  // Typing in the search box keeps page 1, so it never yanks the view.
  PageScroll: {
    mounted() {
      this._page = this.el.dataset.page
    },
    updated() {
      if (this.el.dataset.page !== this._page) {
        this._page = this.el.dataset.page
        this.el.scrollIntoView({ block: "start" })
      }
    },
  },
  // Online presence dots. ShellLive (on every page) pushes this viewer's online
  // user-id set ("presence:set", already filtered against their blocks); this
  // hook reveals each online member's dot via ONE generated stylesheet keyed on
  // the server-rendered data-presence-user-id. Because the rules match by
  // attribute selector (not a JS-set attribute on each node), they keep working
  // for avatars added or re-rendered later — LiveView stream patches (which
  // strip JS-set attributes via morphdom), navigation, classic pages — with no
  // MutationObserver and no per-node bookkeeping to fall out of sync.
  Presence: {
    mounted() {
      this.style = document.createElement("style")
      document.head.appendChild(this.style)

      this.handleEvent("presence:set", ({ online }) => {
        this.style.textContent = (online || [])
          .map(
            (id) =>
              `[data-presence-user-id="${CSS.escape(String(id))}"] .presence-dot{display:block}`
          )
          .join("")
      })
    },
    destroyed() {
      this.style?.remove()
    },
  },
  // Drag-and-drop ordering, shared by the owner's profile-section reorder tool
  // (VutuvWeb.SectionReorderLive) and the feed rail's arrangeable cards.
  // Listeners are delegated to the container so they survive the server
  // re-renders that follow each change. On drop we push the new `data-id` order
  // to the LiveView, which stores it and re-renders (the rows are keyed by id,
  // so the DOM the drag already moved just settles).
  //
  // Two things are per call site, read off the container: `data-reorder-item`
  // (the selector for a row, default the section tool's) and
  // `data-reorder-event` (what is pushed on drop, default "reorder").
  //
  // A row is dragged as a whole unless it carries a [data-reorder-handle], in
  // which case only the handle starts a drag — the feed rail's cards are full
  // of checkboxes, links and text inputs, and a card draggable by any of them
  // is a card whose controls cannot be used. The handle is also the keyboard
  // path: ↑/↓ on it move the row, which is what makes the rail arrangeable
  // without a pointer at all. Touch devices can't fire native HTML5 drag; the
  // section tool has its up/down arrows for that, and the rail is desktop-only.
  Reorder: {
    mounted() {
      this.dragging = null
      const list = this.el
      const selector = list.dataset.reorderItem || ".reorder__item"
      const event = list.dataset.reorderEvent || "reorder"
      const items = () => [...list.querySelectorAll(selector)]
      const push = () => this.pushEvent(event, { order: items().map((el) => el.dataset.id) })

      this._selector = selector

      // Dragging past a row taller than the window was impossible, and not
      // because the gesture was awkward: the drop position is decided by each
      // row's MIDPOINT, and the midpoint of a 700px card sits above the
      // viewport long before its top edge does — so no pointer position ever
      // named it, however patiently you dragged.
      //
      // The cap is the whole fix. A row's reference line is its midpoint but at
      // most `TALL_CAP` into it, so every row behaves like one of at most
      // 2 × TALL_CAP: the pointer never has to travel further than that to put
      // the dragged card before it, whatever the neighbour's height.
      //
      // The obvious alternative — folding the cards to their headings for the
      // length of the drag — was written first and had to come out: mutating
      // the layout (and scrolling) inside `dragstart` cancels the native drag
      // session in WebKit outright, so Safari lost drag-and-drop entirely
      // (2026-08-28). Nothing here touches the DOM while a drag is running.
      //
      // The page still scrolls itself while the pointer rests near a window
      // edge, for the rail that is longer than the window — a row whose top
      // edge is off screen is out of reach whatever the cap does. That scroll
      // runs on its own frame loop rather than on `dragover`, because a pointer
      // held still at the edge stops firing that event in some browsers, which
      // is exactly the moment the reader is waiting for the page to move.
      const TALL_CAP = 120
      const EDGE = 90
      const EDGE_SPEED = 14
      let edgeY = null
      let edgeFrame = null

      const stepEdgeScroll = () => {
        edgeFrame = requestAnimationFrame(stepEdgeScroll)
        if (edgeY == null) return
        const top = edgeY - EDGE
        const bottom = edgeY - (window.innerHeight - EDGE)
        if (top < 0) {
          window.scrollBy(0, Math.max(-EDGE_SPEED, (top / EDGE) * EDGE_SPEED))
        } else if (bottom > 0) {
          window.scrollBy(0, Math.min(EDGE_SPEED, (bottom / EDGE) * EDGE_SPEED))
        }
      }

      const startEdgeScroll = () => {
        edgeY = null
        if (edgeFrame == null) edgeFrame = requestAnimationFrame(stepEdgeScroll)
      }

      const stopEdgeScroll = () => {
        if (edgeFrame != null) cancelAnimationFrame(edgeFrame)
        edgeFrame = null
        edgeY = null
      }

      // The row the dragged element should sit before, by the capped line above.
      const rowAfter = (y) =>
        items()
          .filter((row) => row !== this.dragging)
          .reduce(
            (closest, row) => {
              const box = row.getBoundingClientRect()
              const offset = y - box.top - Math.min(box.height / 2, TALL_CAP)
              return offset < 0 && offset > closest.offset
                ? { offset, element: row }
                : closest
            },
            { offset: Number.NEGATIVE_INFINITY, element: null }
          ).element

      // Handle-only rows are not draggable at rest — a card full of
      // checkboxes, links and text inputs that could be dragged from anywhere
      // is a card whose controls cannot be used — so exactly one row carries
      // the attribute at a time: the one the pointer is HOVERING the grip of.
      //
      // Hovering, not pressing. Arming on `pointerdown` looks equivalent and is
      // not: the browser decides whether a press begins a drag as the press
      // arrives, so an attribute set inside that same handler comes too late
      // for it. The first press then only armed the row and the second one
      // dragged it — every card needed two clicks (reported 2026-08-28).
      //
      // Re-armed on `pointermove` as well as on entering, because a LiveView
      // patch of the rail (a count ticking) strips an attribute the server did
      // not render, and the pointer may already be sitting on the grip when it
      // happens. Both handlers cost nothing once the right row is armed.
      const disarm = () =>
        items().forEach((row) => {
          if (row.querySelector("[data-reorder-handle]")) row.removeAttribute("draggable")
        })

      const arm = (e) => {
        if (this.dragging) return
        const row = e.target.closest("[data-reorder-handle]")?.closest(selector) || null
        if (row && row.getAttribute("draggable") === "true") return
        disarm()
        if (row) row.setAttribute("draggable", "true")
      }

      list.addEventListener("pointerover", arm)
      list.addEventListener("pointermove", arm)
      list.addEventListener("pointerleave", () => {
        if (!this.dragging) disarm()
      })

      list.addEventListener("dragstart", (e) => {
        const row = e.target.closest(selector)
        if (!row) return
        // A row with a handle may only be dragged by it, i.e. only while the
        // hover above has armed it.
        if (row.querySelector("[data-reorder-handle]") && !row.draggable) return
        this.dragging = row
        // `is-dragging` only fades the row, so it changes no geometry. Anything
        // that does — a fold, a scroll — belongs outside `dragstart`.
        row.classList.add("is-dragging")
        startEdgeScroll()
      })

      list.addEventListener("dragend", () => {
        stopEdgeScroll()
        // Deliberately no disarm here: the pointer is still on the grip, so the
        // row has to stay armed or a second drag would need a second press
        // again. `pointerleave` and the next `arm` take it off.
        if (!this.dragging) return
        this.dragging.classList.remove("is-dragging")
        this.dragging = null
        push()
      })

      list.addEventListener("dragover", (e) => {
        e.preventDefault()
        if (!this.dragging) return
        edgeY = e.clientY
        const after = rowAfter(e.clientY)
        if (after == null) {
          list.appendChild(this.dragging)
        } else if (after !== this.dragging) {
          list.insertBefore(this.dragging, after)
        }
      })

      // Keyboard: ↑/↓ on the handle move the row one place. Focus is put back
      // on that handle after the server's patch (see updated), or a reader
      // loses the row they were moving after a single press.
      list.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return
        const handle = e.target.closest("[data-reorder-handle]")
        const row = handle?.closest(selector)
        if (!row) return
        const rows = items()
        const to = rows.indexOf(row) + (e.key === "ArrowUp" ? -1 : 1)
        if (to < 0 || to >= rows.length) return
        e.preventDefault()
        if (e.key === "ArrowUp") {
          rows[to].before(row)
        } else {
          rows[to].after(row)
        }
        this._refocus = row.dataset.id
        push()
      })
    },
    // Animate the arrow/keyboard reorders with FLIP: snapshot each row's top
    // before the server patch (beforeUpdate), then after it (updated) jump each
    // moved row back to where it was and transition to its new spot, so the
    // swap glides instead of teleporting. A drag ends in the same order the DOM
    // already shows, so its delta is 0 and nothing animates. Honors
    // prefers-reduced-motion.
    beforeUpdate() {
      if (reducedMotion()) return
      this._tops = new Map()
      this.el
        .querySelectorAll(this._selector)
        .forEach((el) => this._tops.set(el.dataset.id, el.getBoundingClientRect().top))
    },
    updated() {
      const rows = [...this.el.querySelectorAll(this._selector)]

      if (this._refocus) {
        rows
          .find((el) => el.dataset.id === this._refocus)
          ?.querySelector("[data-reorder-handle]")
          ?.focus()
        this._refocus = null
      }

      if (!this._tops) return
      // Invert: place each moved row at its old position with no transition.
      rows.forEach((el) => {
        const prev = this._tops.get(el.dataset.id)
        if (prev == null) return
        const delta = prev - el.getBoundingClientRect().top
        if (!delta) return
        el.style.transition = "none"
        el.style.transform = `translateY(${delta}px)`
      })
      // Play: next frame, release to the natural position.
      requestAnimationFrame(() => {
        rows.forEach((el) => {
          if (!el.style.transform) return
          el.style.transition = "transform 180ms ease"
          el.style.transform = ""
        })
      })
      this._tops = null
    },
  },
  // Drag-to-reorder for the post composer's photo strip (issue #1104). The
  // sibling of Reorder above, with two differences that matter: the strip is a
  // wrapping grid, so the drop target is found by distance to a tile's centre
  // in BOTH axes rather than by vertical midpoint; and the order is pushed on
  // drop, because a photo set's order is the mosaic's layout — the first photo
  // is the hero — so it must survive the re-render exactly as dropped.
  //
  // Touch cannot fire native HTML5 drag, so the ◀ ▶ buttons (plain phx-click)
  // are the reorder path on a phone; this layers pointer drag on top.
  PhotoStrip: {
    mounted() {
      const strip = this.el
      const tiles = () => [...strip.querySelectorAll("[data-photo-tile]")]

      // The tiles' crop dots open the ratio crop dialog (photo_crop.js); the
      // dialog's verdict goes to the composer LiveComponent, which re-derives
      // the served versions and re-renders the tile. pushEventTo(this.el, …),
      // not pushEvent — same reason as the reorder push below.
      strip.addEventListener("click", (e) => {
        const button = e.target.closest("[data-photo-crop]")
        if (!button) return
        e.preventDefault()
        const labels = {
          title: strip.dataset.cropTitle || "Crop photo",
          hint: strip.dataset.cropHint || "Pick a shape, then drag and zoom.",
          save: strip.dataset.cropSave || "Apply crop",
          cancel: strip.dataset.cropCancel || "Cancel",
          reset: strip.dataset.cropReset || "Whole photo",
          zoom: strip.dataset.cropZoom || "Zoom",
        }
        openPhotoCropper(button, labels, (crop) => {
          this.pushEventTo(this.el, "photo-crop", { id: button.dataset.photoCrop, crop })
        })
      })

      const nearest = (x, y) =>
        tiles()
          .filter((tile) => !drag || tile !== drag.tile)
          .reduce(
            (closest, tile) => {
              const box = tile.getBoundingClientRect()
              const dx = x - (box.left + box.width / 2)
              const dy = y - (box.top + box.height / 2)
              const distance = dx * dx + dy * dy
              return distance < closest.distance
                ? { distance, tile, before: dx < 0 }
                : closest
            },
            { distance: Number.POSITIVE_INFINITY, tile: null, before: false }
          )

      // Pointer-drag reorder — one mechanism for mouse AND touch (the ◀ ▶
      // arrow dots that used to be the touch path are gone). The rules that
      // make it coexist with everything else on the tile:
      //
      //   * Mouse: the drag lifts on the first real movement (~6px), so a
      //     plain click still opens the photo panel.
      //   * Touch: the drag lifts after a short hold (220ms) with the finger
      //     still; moving before that is scrolling and cancels the lift, so
      //     the page keeps scrolling normally over the photos. Once lifted, a
      //     non-passive touchmove preventDefault keeps the browser from
      //     starting a scroll mid-drag.
      //   * After a lifted drop, the release's click is swallowed once so
      //     dropping a tile does not also open its options panel.
      //
      // The tile is moved live in the DOM while dragging; on release the id
      // order is pushed (pushEventTo, not pushEvent: the composer is a
      // LiveComponent) and the server's re-render just settles what the
      // author already sees.
      const HOLD_MS = 220
      const LIFT_CLASSES = ["opacity-60", "z-10", "scale-[1.03]", "shadow-xl"]
      let drag = null

      const lift = () => {
        if (!drag) return
        drag.lifted = true
        drag.tile.classList.add(...LIFT_CLASSES)
        // Explicit capture so a mouse drag released outside the grid still
        // delivers its pointerup here (touch captures implicitly).
        try {
          drag.tile.setPointerCapture(drag.pointerId)
        } catch (_e) {
          // A tile re-rendered mid-gesture cannot capture; the drag still
          // works while the pointer stays over the grid.
        }
      }

      const settle = (fromPointerUp) => {
        if (!drag) return
        clearTimeout(drag.timer)
        drag.tile.classList.remove(...LIFT_CLASSES)
        if (drag.lifted) {
          // A lifted drop must not also open the photo panel: swallow the
          // click the release generates (only on a real pointerup — a
          // cancelled drag produces no click, and the guard must not linger
          // to eat the author's next intentional one).
          if (fromPointerUp) {
            strip.addEventListener(
              "click",
              (e) => {
                e.stopPropagation()
                e.preventDefault()
              },
              { capture: true, once: true }
            )
          }
          this.pushEventTo(this.el, "photo-reorder", {
            order: tiles().map((tile) => tile.dataset.photoTile),
          })
        }
        drag = null
      }

      strip.addEventListener("pointerdown", (e) => {
        const frame = e.target.closest("[data-photo-drag]")
        if (!frame || drag || (e.pointerType === "mouse" && e.button !== 0)) return
        // The corner dots (remove, crop) are click targets, never drag
        // handles — a drag started there would eat their click.
        if (e.target.closest("[data-photo-crop], [phx-click='remove-image']")) return
        drag = {
          tile: frame.closest("[data-photo-tile]"),
          pointerId: e.pointerId,
          x: e.clientX,
          y: e.clientY,
          touch: e.pointerType !== "mouse",
          lifted: false,
          timer: null,
        }
        if (drag.touch) drag.timer = setTimeout(lift, HOLD_MS)
      })

      strip.addEventListener("pointermove", (e) => {
        if (!drag || e.pointerId !== drag.pointerId) return
        if (!drag.lifted) {
          const moved = Math.hypot(e.clientX - drag.x, e.clientY - drag.y)
          if (drag.touch) {
            // Moving before the hold ends is a scroll, not a drag.
            if (moved > 8) {
              clearTimeout(drag.timer)
              drag = null
            }
            return
          }
          if (moved <= 6) return
          lift()
        }
        const { tile, before } = nearest(e.clientX, e.clientY)
        if (!tile) return
        if (before) strip.insertBefore(drag.tile, tile)
        else strip.insertBefore(drag.tile, tile.nextSibling)
      })

      // Once lifted, the finger is dragging a tile, not the page.
      strip.addEventListener(
        "touchmove",
        (e) => {
          if (drag && drag.lifted) e.preventDefault()
        },
        { passive: false }
      )

      strip.addEventListener("pointerup", (e) => {
        if (drag && e.pointerId === drag.pointerId) settle(true)
      })
      strip.addEventListener("pointercancel", (e) => {
        if (drag && e.pointerId === drag.pointerId) settle(false)
      })

      // A long touch-hold must lift the tile, not open the OS context menu
      // (Android fires it around the 500ms mark, well after our lift).
      strip.addEventListener("contextmenu", (e) => {
        if (drag) e.preventDefault()
      })
    },
  },
}

// The mark a pressed nav item wears while its page is on its way. See the nav
// press handler below; the paint itself is the press block in `app.css`.
const NAV_PRESSING = "data-nav-pressing"

// A disclosure whose open/closed state is the reader's, not the server's.
const KEEP_OPEN = "data-keep-open"

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken() },
  hooks: Hooks,
  dom: {
    // Both navs live inside ShellLive, so a patch that has nothing to do with
    // them — an unread badge ticking, the people total arriving — still walks
    // these nodes, and morphdom drops every attribute the server did not
    // render. That would wipe the press paint half a second into a page load,
    // rarely and unreproducibly. LiveView carries its OWN in-flight markers
    // across a patch for exactly this reason; ours has to say so here.
    onBeforeElUpdated(from, to) {
      if (from.hasAttribute(NAV_PRESSING)) to.setAttribute(NAV_PRESSING, "")

      // A <details data-keep-open> the reader opened or closed themselves. The
      // server renders the STARTING position once and has nothing to say about
      // it afterwards, so morphdom must not restore that starting position on
      // every later patch — for the tag timeline's filter panel that is a live
      // count tick folding the panel shut while somebody is typing in it. Opt
      // in per element: a disclosure the server really does drive (one that
      // opens because its content changed) must keep taking its state from the
      // render, so it carries no marker.
      if (from.hasAttribute(KEEP_OPEN)) {
        from.open ? to.setAttribute("open", "") : to.removeAttribute("open")
      }
    },
  },
})

liveSocket.connect()
window.liveSocket = liveSocket

// A filter tab pressed before anything is listening. The All / vutuv /
// Fediverse tabs are `phx-click` buttons, and LiveView binds a button only once
// the view holding it has joined — the page's own socket, and after that the
// embedded child's for the profile and the tag timeline. Until then a press
// reaches nothing whatsoever: no request, no paint, and no retry when the
// socket does arrive, so on a slow line the reader presses a tab, waits, and
// stays where they were. Measured over CDP: still on "All" six seconds later.
//
// What decides that a press was lost is its EFFECT, not the socket state —
// `liveSocket.isConnected()` is already true while an embedded child is still
// joining, which is the long-known swallowed first click. LiveView stamps
// `data-phx-ref-loading` on the element it is pushing for (view.js `putRef`),
// so a tab carrying neither that nor the pressed state a moment later was never
// heard, and pressing it again is safe: picking a filter is idempotent.
//
// Read the REF, never the `phx-click-loading` class: the paint below puts that
// same class on by hand, so a ticker testing it would read its own paint as
// LiveView's answer and give up on the very slow joins this exists for.
const TAB_PRESS_RETRY_MS = 500
const TAB_PRESS_RETRIES = 12

function retryFilterPress(tab) {
  let left = TAB_PRESS_RETRIES

  const tick = () => {
    // Heard: LiveView is carrying it, or the answer has already landed.
    if (tab.hasAttribute("data-phx-ref-loading") || tab.getAttribute("aria-pressed") === "true") {
      delete tab.dataset.filterRetrying
      return
    }

    if (!tab.isConnected || left-- <= 0) {
      // Stop claiming work nobody is doing.
      tab.classList.remove("phx-click-loading")
      delete tab.dataset.filterRetrying
      return
    }

    tab.click()
    setTimeout(tick, TAB_PRESS_RETRY_MS)
  }

  setTimeout(tick, TAB_PRESS_RETRY_MS)
}

document.addEventListener("click", (e) => {
  const tab = e.target.closest("[data-filter-tab]")
  // Only a button can lose a press. A tab that is a link needs none of this and
  // must not get it: the `/:slug/posts` archive is a plain navigation, and the
  // /notifications tabs are `<.link patch>`, which LiveView turns into a full
  // page load whenever the socket is not up yet — so the early press that would
  // be lost here already lands there, as an ordinary GET of the same URL.
  if (!tab || tab.tagName !== "BUTTON") return
  if (tab.getAttribute("aria-pressed") === "true") return
  // Our own retry clicks bubble back in here — one ticker per press.
  if (tab.dataset.filterRetrying) return

  tab.dataset.filterRetrying = "1"
  // Paint the press even while nothing is listening yet. Once a press does
  // land, LiveView's own ack takes the class off again.
  tab.classList.add("phx-click-loading")
  retryFilterPress(tab)
})

// A nav item pressed, and a whole document to wait for. The top bar's Feed /
// Profile / Network / Jobs and the phone's bottom tab bar are plain links on
// purpose (they cross live_sessions), so there is no socket round trip to hang
// feedback off and no ack to end it: the pill sits on the page being left
// until the next document paints, which on a slow line is the same dead
// control the filter tabs had. So the press is painted here and the new
// document's own render is what takes it off — no timer, nothing to expire.
document.addEventListener("click", (e) => {
  const item = e.target.closest("[data-nav-item]")
  if (!item) return
  // Three presses that leave THIS document exactly as it is, so painting any
  // of them would be a lie: one that opens a new tab or window, one already
  // handled by something else, and one on the page the reader is on.
  if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  if (item.target === "_blank") return
  if (item.getAttribute("aria-current") === "page") return

  item.setAttribute(NAV_PRESSING, "")
  // On the root, because `<main>` is outside the shell LiveView that holds the
  // navs — that is the element the dim has to reach.
  document.documentElement.setAttribute(NAV_PRESSING, "")
})

// Back from the bfcache hands this document back exactly as it was left: mid
// press, still painted for a page the reader has since walked away from. A
// restore fires `pageshow` and an ordinary load fires it too, so one listener
// covers both.
window.addEventListener("pageshow", () => {
  document.documentElement.removeAttribute(NAV_PRESSING)
  document
    .querySelectorAll(`[data-nav-item][${NAV_PRESSING}]`)
    .forEach((el) => el.removeAttribute(NAV_PRESSING))
})

// Flash toasts. Lives outside LiveView so it also works on classic controller
// pages: EVERY toast (info and error alike) auto-dismisses after a few seconds,
// the × button closes it early, and a MutationObserver gives the same treatment
// to toasts a LiveView pushes into the tray later. One knob for the whole app.
const TOAST_DISMISS_MS = 3000

function wireToast(el) {
  if (!once(el, "toast")) return

  // Both ways out go through the close button, because on a LiveView page its
  // phx-click="lv:clear-flash" also clears the server-side flash — without that
  // a later patch resurrects the dismissed toast, and the very same sentence
  // never draws a toast a second time. Which is why the detach waits for the
  // NEXT tick: LiveView listens for phx-click on the window, so it sees the ×
  // only while the toast is still in the document.
  const closeBtn = el.querySelector("[data-toast-close]")
  if (closeBtn) {
    closeBtn.addEventListener("click", () => setTimeout(() => el.remove()))
  }

  setTimeout(() => (closeBtn ? closeBtn.click() : el.remove()), TOAST_DISMISS_MS)
}

function setupToasts() {
  const tray = document.getElementById("toast-tray")
  if (!tray) return

  tray.querySelectorAll(".toast").forEach(wireToast)

  // `subtree`, not just the tray's own children: an embedded LiveView reaches
  // the tray through `<.portal>` (LayoutHTML.embedded_flash), which lands its
  // toasts one wrapper deep.
  if (once(tray, "toastObserver")) {
    new MutationObserver((mutations) => {
      mutations.forEach((m) =>
        m.addedNodes.forEach((node) => {
          if (node.nodeType !== 1) return
          if (node.classList.contains("toast")) wireToast(node)
          node.querySelectorAll(".toast").forEach(wireToast)
        })
      )
    }).observe(tray, { childList: true, subtree: true })
  }
}

onReady(setupToasts)

// Username availability. The new-username form (slug/form_content) marks its
// input with data-availability-url; as the user types, ask the server whether
// the handle is valid and free and show the verdict in the #username-availability
// hint line, so "already taken" appears before the form is submitted. Plain
// JS on a classic controller page (no LiveView there).
function setupSlugAvailability() {
  const input = document.querySelector("input[data-availability-url]")
  const hint = document.getElementById("username-availability")
  if (!input || !hint || !once(input, "slug")) return

  let timer = null

  input.addEventListener("input", () => {
    clearTimeout(timer)
    const value = input.value.trim()

    if (value === "") {
      hint.textContent = ""
      hint.classList.remove("editform__hint--ok", "editform__hint--error")
      return
    }

    timer = setTimeout(async () => {
      try {
        const url = `${input.dataset.availabilityUrl}?value=${encodeURIComponent(value)}`
        // No explicit Accept header: the route lives in the :browser pipeline,
        // whose `accepts ["html"]` 406s an "application/json" Accept; fetch's
        // default */* negotiates fine and the action responds with JSON anyway.
        const resp = await fetch(url)
        if (!resp.ok) return
        const data = await resp.json()
        // A slower response for an older value must not overwrite the verdict
        // for what is in the input now.
        if (input.value.trim() !== value) return
        hint.textContent = data.message
        hint.classList.toggle("editform__hint--ok", data.available)
        hint.classList.toggle("editform__hint--error", !data.available)
      } catch (_e) {
        // Network hiccup: keep quiet, the server still validates on submit.
      }
    }, 300)
  })
}

onReady(setupSlugAvailability)

// Work-experience organization link (issue #931). The work-experience form marks a
// [data-organization-link] box; as the member types the organization, ask the server
// for a matching verified organization page and offer a quiet one-tap link. The
// hidden work_experience[organization_id] carries the choice. No match -> no UI.
// Plain JS on a classic controller page (no LiveView there).
function setupOrganizationLink() {
  document.querySelectorAll("[data-organization-link]").forEach((box) => {
    if (!once(box, "organizationLink")) return
    const form = box.closest("form")
    if (!form) return
    const orgInput = form.querySelector('[name$="[organization]"]')
    const idInput = box.querySelector('[name$="[organization_id]"]')
    const status = box.querySelector("[data-organization-link-status]")
    if (!orgInput || !idInput || !status) return

    const labels = {
      suggest: box.dataset.labelSuggest || "Link to {name}?",
      link: box.dataset.labelLink || "Link to page",
      linked: box.dataset.labelLinked || "Linked to {name}",
      unlink: box.dataset.labelUnlink || "Remove link",
    }

    // Seed the already-linked organization (editing a linked experience), so the
    // linked state renders with the organization name even before the first fetch.
    let linked =
      idInput.value && box.dataset.linkedId === idInput.value
        ? { id: box.dataset.linkedId, name: box.dataset.linkedName || "", path: box.dataset.linkedPath || "" }
        : null
    let suggestion = null
    let timer = null

    // A label template holding a "{name}" placeholder, rendered with the name as
    // a real element (link/strong) so it is never HTML-injected as a string.
    function render(template, nameEl, actionEl) {
      const [before, after] = template.split("{name}")
      const frag = document.createDocumentFragment()
      frag.append(document.createTextNode(before))
      if (nameEl) frag.append(nameEl)
      frag.append(document.createTextNode(after !== undefined ? after : ""))
      if (actionEl) frag.append(document.createTextNode(" "), actionEl)
      status.replaceChildren(frag)
      status.hidden = false
    }

    function button(text, className, onClick) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.textContent = text
      btn.className = className
      btn.addEventListener("click", onClick)
      return btn
    }

    function renderState() {
      if (linked) {
        const nameEl = linked.path
          ? Object.assign(document.createElement("a"), {
              href: linked.path,
              textContent: linked.name,
              target: "_blank",
              rel: "noopener",
              className: "font-semibold",
            })
          : Object.assign(document.createElement("strong"), { textContent: linked.name })
        const unlink = button(labels.unlink, "font-semibold text-slate-600 underline hover:text-slate-800", () => {
          idInput.value = ""
          linked = null
          renderState()
          check()
        })
        render(labels.linked, nameEl, unlink)
      } else if (suggestion && suggestion.id !== idInput.value) {
        const nameEl = Object.assign(document.createElement("strong"), { textContent: suggestion.name })
        const link = button(labels.link, "font-semibold text-brand-600 underline hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300", () => {
          idInput.value = suggestion.id
          linked = suggestion
          suggestion = null
          renderState()
        })
        render(labels.suggest, nameEl, link)
      } else {
        status.hidden = true
        status.replaceChildren()
      }
    }

    async function check() {
      if (linked) return
      const value = orgInput.value.trim()
      if (value.length < 2) {
        suggestion = null
        return renderState()
      }
      try {
        const url = `${box.dataset.suggestUrl}?q=${encodeURIComponent(value)}`
        const resp = await fetch(url)
        if (!resp.ok) return
        const data = await resp.json()
        // Ignore a stale response for an organization value already replaced.
        if (orgInput.value.trim() !== value) return
        suggestion = data.organization
        renderState()
      } catch (_e) {
        // Network hiccup: stay quiet, the free-text organization still works.
      }
    }

    orgInput.addEventListener("input", () => {
      if (linked) return // keep the accepted link; unlink first to change it
      clearTimeout(timer)
      timer = setTimeout(check, 300)
    })

    renderState()
    if (!linked) check()
  })
}

onReady(setupOrganizationLink)

// Make horizontally-scrollable code blocks and tables in rendered Markdown
// keyboard-focusable, so they can be scrolled without a mouse (WCAG 2.1.1).
function markFocusableScrollers() {
  document.querySelectorAll(".markdown pre, .markdown table").forEach((el) => {
    if (el.scrollWidth > el.clientWidth && !el.hasAttribute("tabindex")) {
      el.tabIndex = 0
    }
  })
}
onReady(markFocusableScrollers)

// Tag endorsement pills on the profile (VutuvWeb.UI.tag_vote): each is a CSRF
// <form data-tag-vote> whose single count pill is the toggle button. Enhance it to
// toggle the endorsement over fetch (POST to endorse, DELETE to undo) instead of a
// full page reload, then pop the count when it changes. The form's action/method
// are the no-JS fallback; once wired we always intercept. The server returns the
// fresh {count, endorsed}; flipping data-endorsed restyles the pill via the
// data-[endorsed=true]: utilities. Classic controller page, so plain JS (no
// LiveView here).
function popCount(el) {
  if (reducedMotion()) return
  el.animate(
    [{ transform: "scale(1)" }, { transform: "scale(1.4)" }, { transform: "scale(1)" }],
    { duration: 260, easing: "ease-out" }
  )
}

// Keep the chip's hover roster in step with a toggle: show/hide the viewer's own
// pre-rendered row, then enable hover only while at least one row is visible.
function updateRoster(form, endorsed) {
  const chip = form.closest(".group")
  const popover = chip && chip.querySelector("[data-roster]")
  if (!popover) return

  const selfRow = popover.querySelector("[data-self-endorser]")
  if (selfRow) selfRow.classList.toggle("hidden", !endorsed)

  const hasRows = popover.querySelector("[data-roster-row]:not(.hidden)") !== null
  popover.classList.toggle("group-hover:block", hasRows)
  popover.classList.toggle("group-focus-within:block", hasRows)
}

function wireTagVote(form) {
  if (!once(form, "tagVote")) return

  const button = form.querySelector("button")
  const countEl = form.querySelector("[data-tag-vote-count]")

  form.addEventListener("submit", async (e) => {
    e.preventDefault()
    if (form.dataset.busy) return
    form.dataset.busy = "1"

    const endorsed = button.dataset.endorsed === "true"
    const url = endorsed ? form.dataset.unendorseUrl : form.dataset.endorseUrl
    const method = endorsed ? "DELETE" : "POST"

    try {
      const resp = await request(url, { method })
      if (!resp.ok) throw new Error(`tag vote ${resp.status}`)
      const { count, endorsed: nowEndorsed } = await resp.json()

      button.dataset.endorsed = String(nowEndorsed)
      button.setAttribute("aria-pressed", String(nowEndorsed))
      button.title = nowEndorsed ? form.dataset.labelUnendorse : form.dataset.labelEndorse

      // The pill shows a "+" (invite to endorse) only while nobody has, so a
      // count that drops to 0 reverts to "+" rather than showing a bare "0".
      const display = !nowEndorsed && count === "0" ? "+" : count
      if (countEl.textContent.trim() !== display) {
        countEl.textContent = display
        popCount(countEl)
      }

      // Reflect the change in the hover roster: reveal/hide the viewer's own
      // pre-rendered row, and only enable hover while the popover has a row to show
      // (so a freshly-unendorsed tag with no other endorsers stops popping an empty
      // card on hover).
      updateRoster(form, nowEndorsed)
    } catch (_e) {
      // Network/permission hiccup: leave the pill as it was; a reload re-syncs.
    } finally {
      delete form.dataset.busy
    }
  })
}

function setupTagVotes() {
  document.querySelectorAll("form[data-tag-vote]").forEach(wireTagVote)
}
onReady(setupTagVotes)

// Map links on the profile address card (user/show + Vutuv.Maps). A logged-in
// viewer has a default map service rendered as the primary "Open in …" button,
// the rest as a quiet "Also on" line. Clicking an alternative promotes it: the
// map opens in a new tab, the clicked service becomes the primary button on
// every address row at once, and the new default is persisted (keepalive POST,
// so it survives the tab switch). The links are real <a> tags, so with JS off
// they still open — the default just stays put. Rows without a persist URL
// (logged-out visitors) are left as plain links. Classic controller page, so
// plain JS (no LiveView here).
function mapSnapshot(link) {
  return {
    service: link.dataset.service,
    href: link.getAttribute("href"),
    labelPrimary: link.dataset.labelPrimary,
    labelAlt: link.dataset.labelAlt,
  }
}

function mapApply(link, data, asPrimary) {
  link.dataset.service = data.service
  link.setAttribute("href", data.href)
  link.dataset.labelPrimary = data.labelPrimary
  link.dataset.labelAlt = data.labelAlt
  const text = link.querySelector("[data-map-text]")
  if (text) text.textContent = asPrimary ? data.labelPrimary : data.labelAlt
}

// Across every address row, swap the primary button with the matching
// alternative so `service` reads as the primary everywhere at once.
function promoteMapDefault(service) {
  document.querySelectorAll("[data-map-row]").forEach((row) => {
    const primary = row.querySelector("[data-map-primary]")
    if (!primary || primary.dataset.service === service) return
    const alt = row.querySelector(`[data-map-alt][data-service="${service}"]`)
    if (!alt) return
    const wasPrimary = mapSnapshot(primary)
    const wasAlt = mapSnapshot(alt)
    mapApply(primary, wasAlt, true)
    mapApply(alt, wasPrimary, false)
  })
}

function persistMapDefault(url, service) {
  try {
    request(url, {
      method: "POST",
      keepalive: true,
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `service=${encodeURIComponent(service)}`,
    })
  } catch (_e) {
    // Best effort: a reload re-reads the stored default anyway.
  }
}

function wireMapRow(row) {
  if (!once(row, "map")) return
  const persistUrl = row.dataset.mapPersistUrl
  if (!persistUrl) return // logged-out: plain links, no promotion
  row.querySelectorAll("[data-map-alt]").forEach((alt) => {
    alt.addEventListener("click", (e) => {
      e.preventDefault()
      const service = alt.dataset.service
      window.open(alt.getAttribute("href"), "_blank", "noopener,noreferrer")
      promoteMapDefault(service)
      persistMapDefault(persistUrl, service)
    })
  })
}

function setupMapLinks() {
  document.querySelectorAll("[data-map-row]").forEach(wireMapRow)
}
onReady(setupMapLinks)

// The viewer's own time zone (issue #1502). The browser is the only side that
// knows it, so it fills two things: the sign-up form's hidden field, which
// stamps the new account with its zone (Vutuv.Accounts), and the hint under the
// zone select on /settings/preferences, so an existing member picks theirs by
// clicking the name their browser reports instead of hunting through 313
// options. The sentence and its "{zone}" marker come from the server, which is
// the only side that knows the reader's language.
function browserTimeZone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || ""
  } catch (e) {
    return ""
  }
}

function offerBrowserTimeZone(hint, zone) {
  const select = document.getElementById(hint.dataset.select)
  // Nothing worth offering when the select already stands on that zone, or
  // when it does not carry it at all (an ICU alias our menu doesn't list).
  if (!select || select.value === zone) return
  if (!Array.from(select.options).some((option) => option.value === zone)) return

  const [before, after] = hint.dataset.label.split("{zone}")
  const button = document.createElement("button")
  button.type = "button"
  button.textContent = zone
  button.className =
    "font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
  button.addEventListener("click", () => {
    select.value = zone
    hint.hidden = true
  })

  hint.textContent = before || ""
  hint.appendChild(button)
  if (after) hint.appendChild(document.createTextNode(after))
  hint.hidden = false
}

function setupTimeZoneFields() {
  const zone = browserTimeZone()
  if (!zone) return

  document
    .querySelectorAll("input[data-timezone-field]")
    .forEach((input) => (input.value = zone))
  document
    .querySelectorAll("[data-browser-timezone]")
    .forEach((hint) => offerBrowserTimeZone(hint, zone))
}
onReady(setupTimeZoneFields)

// Drag-and-drop for the LinkedIn import ZIP (Step 2 of the import page). The
// <label data-dropzone> wraps a real, sr-only file input, so the form still
// posts multipart exactly as before and the picker/submit work with JS off —
// this only lets the member drop a file onto the zone, highlights it while a
// file is dragged over, and shows the chosen filename. Classic controller page,
// so plain JS suffices.
function wireDropzone(zone) {
  if (!once(zone, "dropzone")) return
  const input = zone.querySelector("[data-dropzone-input]")
  if (!input) return
  const prompt = zone.querySelector("[data-dropzone-prompt]")
  const name = zone.querySelector("[data-dropzone-name]")
  // Optional size guard: the zone carries the byte cap and a localized
  // message, so an oversized pick is flagged (and the submit disabled) before
  // the member waits out a doomed upload. The server still enforces the cap.
  const error = zone.querySelector("[data-dropzone-error]")
  const form = zone.closest("form")
  const submit = form && form.querySelector('button[type="submit"]')
  const maxBytes = parseInt(zone.dataset.maxBytes || "", 10)

  const showChosen = () => {
    const file = input.files && input.files[0]
    if (!file || !name) return
    const tooBig = Boolean(maxBytes) && file.size > maxBytes
    name.textContent = file.name
    name.classList.remove("hidden")
    if (prompt) prompt.classList.add("hidden")
    if (error) {
      error.textContent = tooBig ? zone.dataset.tooLarge || "" : ""
      error.classList.toggle("hidden", !tooBig)
    }
    if (submit) submit.disabled = tooBig
  }

  input.addEventListener("change", showChosen)

  ;["dragenter", "dragover"].forEach((ev) =>
    zone.addEventListener(ev, (e) => {
      e.preventDefault()
      zone.dataset.dragover = "true"
    })
  )
  ;["dragleave", "dragend"].forEach((ev) =>
    zone.addEventListener(ev, (e) => {
      // Ignore dragleave bubbling up from a child element still inside the zone.
      if (ev === "dragleave" && zone.contains(e.relatedTarget)) return
      delete zone.dataset.dragover
    })
  )

  zone.addEventListener("drop", (e) => {
    e.preventDefault()
    delete zone.dataset.dragover
    const dropped = e.dataTransfer && e.dataTransfer.files
    if (!dropped || !dropped.length) return
    // Non-multiple input: keep just the first file, via a fresh DataTransfer.
    const dt = new DataTransfer()
    dt.items.add(dropped[0])
    input.files = dt.files
    showChosen()
  })
}

function setupDropzones() {
  document.querySelectorAll("[data-dropzone]").forEach(wireDropzone)
}
onReady(setupDropzones)

// "Select all / deselect all" toggle for each candidate group on the LinkedIn
// import preview page. Progressive: the button starts hidden and does nothing
// with JS off (the checkboxes are still individually selectable), so this only
// adds a one-click flip over every checkbox inside the enclosing
// [data-select-group]. The button carries both localized labels as data-* so
// no translated text is hardcoded here.
//
// A group may carry a cap in data-select-limit — the tags do, because a profile
// holds at most Vutuv.Tags.max_user_tags/0 of them. Then the toggle fills the
// cap instead of ticking everything, a tick past it is refused with the
// group's own notice line, and [data-select-free] counts the remaining slots
// down. A [data-duplicate] box never counts against the cap: the member already
// has that entry, so submitting it spends no slot. The server preselects within
// the same cap, so none of this is what keeps the import correct — it is what
// keeps the page from promising an import it cannot deliver (issue #1478).
function selectLimit(group) {
  const raw = parseInt(group.dataset.selectLimit ?? "", 10)
  return Number.isNaN(raw) ? null : raw
}

// Boxes that spend a slot, i.e. everything the member does not already have.
function countingBoxes(group) {
  return [
    ...group.querySelectorAll('input[type="checkbox"]:not([data-duplicate])'),
  ]
}

function showSelectNotice(group, show) {
  const notice = group.querySelector("[data-select-notice]")
  if (notice) notice.hidden = !show
}

// The live "N of M free slots selected" line, rebuilt from the whole sentence
// the server put on the element, so no wording lives here. It counts what is
// SELECTED, not what is left: the page arrives with its free slots already
// ticked, and a "you can pick N more" line would greet every member with a
// zero.
function syncFreeCount(group, limit) {
  const el = group.querySelector("[data-select-free]")
  if (!el) return
  const chosen = countingBoxes(group).filter((b) => b.checked).length
  const template = el.dataset.labelSelected
  if (template) {
    el.textContent = template
      .replace("{n}", String(chosen))
      .replace("{max}", String(limit))
  }
}

function wireSelectAll(btn) {
  if (!once(btn, "selectAll")) return
  const group = btn.closest("[data-select-group]")
  if (!group) return
  const limit = selectLimit(group)
  const boxes = () => [...group.querySelectorAll('input[type="checkbox"]')]

  // A full profile has nothing to offer here: the per-box guard below still
  // refuses every tick, but a "select" button that can never select anything
  // is noise, so it stays hidden.
  const wireToggle = limit !== 0

  const sync = () => {
    const all = boxes()
    const allChecked = all.length > 0 && all.every((b) => b.checked)
    // At a cap, "all" means "as many as fit" — otherwise the button would
    // never reach its deselect state on a group it can never fill.
    const filled =
      limit !== null &&
      countingBoxes(group).filter((b) => b.checked).length >= limit
    btn.dataset.state = allChecked || filled ? "all" : "some"
    btn.textContent =
      btn.dataset.state === "all"
        ? btn.dataset.labelDeselect
        : btn.dataset.labelSelect
    if (limit !== null) syncFreeCount(group, limit)
  }

  btn.addEventListener("click", () => {
    const check = btn.dataset.state !== "all"
    let budget = limit === null ? Infinity : limit
    boxes().forEach((b) => {
      if (!check) {
        b.checked = false
        return
      }
      const counts = !b.hasAttribute("data-duplicate")
      if (counts && budget <= 0) {
        b.checked = false
        return
      }
      b.checked = true
      if (counts) budget -= 1
    })
    showSelectNotice(group, false)
    sync()
  })

  // Keep the label honest when the member toggles individual boxes by hand,
  // and refuse a tick that would overrun the cap.
  group.addEventListener("change", (e) => {
    const box = e.target
    if (!box.matches('input[type="checkbox"]')) return

    if (
      limit !== null &&
      box.checked &&
      !box.hasAttribute("data-duplicate") &&
      countingBoxes(group).filter((b) => b.checked).length > limit
    ) {
      box.checked = false
      showSelectNotice(group, true)
    } else if (!box.checked) {
      showSelectNotice(group, false)
    }

    sync()
  })

  if (wireToggle) btn.classList.remove("hidden")
  sync()
}

function setupSelectAll() {
  document.querySelectorAll("[data-select-all]").forEach(wireSelectAll)
}
onReady(setupSelectAll)

// "Type your username to confirm" gate on the account-deletion page
// (<form data-delete-gate>, see settings/delete_account.html.heex). Progressive
// enhancement only: with JS off the red button stays clickable and the server
// re-checks the username (UserController.delete), so this just disables the
// button until the field matches, sparing a needless round-trip. The match is
// normalized the same way the server does it: trim, drop a leading "@",
// lower-case.
function normalizeUsername(value) {
  return value.trim().replace(/^@+/, "").toLowerCase()
}

function wireDeleteGate(form) {
  if (!once(form, "deleteGate")) return
  const input = form.querySelector("[data-delete-gate-input]")
  const submit = form.querySelector("[data-delete-gate-submit]")
  const expected = normalizeUsername(form.dataset.username || "")
  if (!input || !submit || !expected) return

  const sync = () => {
    submit.disabled = normalizeUsername(input.value) !== expected
  }

  input.addEventListener("input", sync)
  sync()
}

function setupDeleteGate() {
  document.querySelectorAll("form[data-delete-gate]").forEach(wireDeleteGate)
}
onReady(setupDeleteGate)

// Copy-to-clipboard button ([data-copy], see settings/security.html.heex's
// permanent profile link). Progressive enhancement: with JS off the target is
// select-all so it can be copied by hand; this just makes it one click. The
// button copies the textContent of the element named by data-copy-target (an
// id) and, for ~1.5s, swaps its label from data-label-copy to data-label-copied
// so no translated text is hardcoded here. writeText needs a secure context
// (https or localhost — every place vutuv runs), so a hidden-textarea +
// execCommand fallback covers older/insecure ones.
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text)
  }
  const area = document.createElement("textarea")
  area.value = text
  area.setAttribute("readonly", "")
  area.style.position = "absolute"
  area.style.left = "-9999px"
  document.body.appendChild(area)
  area.select()
  try {
    document.execCommand("copy")
    return Promise.resolve()
  } catch (err) {
    return Promise.reject(err)
  } finally {
    document.body.removeChild(area)
  }
}

function wireCopyButton(btn) {
  if (!once(btn, "copy")) return
  const target = document.getElementById(btn.dataset.copyTarget)
  const source = () =>
    btn.dataset.copyText || (target ? target.textContent.trim() : "")
  const copied = btn.dataset.labelCopied
  const idle = btn.dataset.labelCopy || btn.textContent
  let revert

  btn.addEventListener("click", () => {
    copyText(source())
      .then(() => {
        if (!copied) return
        btn.textContent = copied
        clearTimeout(revert)
        revert = setTimeout(() => {
          btn.textContent = idle
        }, 1500)
      })
      .catch(() => {})
  })
}

function setupCopyButtons() {
  document.querySelectorAll("[data-copy]").forEach(wireCopyButton)
}
onReady(setupCopyButtons)

// Filter box on the settings hub ([data-settings-filter], see
// settings/index.html.heex). The hub lists ~28 rows across five groups; even
// well grouped, a member who does not know our vocabulary has to read all of
// them. Typing narrows the map to matching rows and hides the groups that empty
// out.
//
// Each row carries a prebuilt lowercase haystack in data-search
// (VutuvWeb.UI.settings_search_text/1: label + hint + a list of synonyms), so
// "Passwort", "Handle" or "abmelden" find the right row even though no label
// says those words, and the matching stays translated with the page.
//
// Rows and groups are hidden with the plain `hidden` ATTRIBUTE, never a class:
// neither element carries a Tailwind display utility, so nothing can out-cascade
// it the way `.inline-block` beat `.hidden` in issue #880. Every token must
// match (AND), so "mail benachricht" narrows rather than widens.
function wireSettingsFilter(input) {
  if (!once(input, "settingsFilter")) return
  const scope = input.closest("[data-settings-map]") || document
  const rows = [...scope.querySelectorAll("[data-settings-row]")]
  const groups = [...scope.querySelectorAll("[data-settings-group]")]
  const empty = scope.querySelector("[data-settings-empty]")

  const apply = () => {
    const terms = input.value.trim().toLowerCase().split(/\s+/).filter(Boolean)
    let hits = 0

    rows.forEach((row) => {
      const haystack = row.dataset.search || ""
      const show = terms.every((term) => haystack.includes(term))
      row.hidden = !show
      if (show) hits++
    })

    // A group whose rows all went away is just a stray heading.
    groups.forEach((group) => {
      group.hidden = ![...group.querySelectorAll("[data-settings-row]")].some(
        (row) => !row.hidden
      )
    })

    if (empty) empty.hidden = hits > 0
  }

  input.addEventListener("input", apply)
  // A browser restoring a typed value on back-navigation must not leave the
  // full list showing under a non-empty box.
  apply()
}

function setupSettingsFilter() {
  document.querySelectorAll("[data-settings-filter]").forEach(wireSettingsFilter)
}
onReady(setupSettingsFilter)

// The status block on /settings/notifications: what THIS browser answers,
// beside the switch that stores what the member wants.
function wireBrowserNotifications(status) {
  if (!once(status, "browserNotifications")) return
  const box = status.closest("form").querySelector('input[type="checkbox"]')
  const lines = [...status.querySelectorAll("[data-notify-state]")]

  // The verdict under the test button. It ships empty and hidden; the two
  // sentences ride the element as data- strings, because the server is the
  // only side that knows the reader's language (the lightbox arrangement).
  const note = status.querySelector("[data-notify-test-result]")
  let waiting = null

  const settle = (message) => {
    if (waiting) clearTimeout(waiting)
    waiting = null
    if (note) {
      note.textContent = message || ""
      note.hidden = !message
    }
  }

  // All four lines ship rendered and switched off by the plain `hidden`
  // attribute (the issue #880 trap: a display utility would out-cascade it);
  // exactly the one that applies is revealed, and none of them while the
  // switch is off, where what this browser thinks does not matter yet.
  const apply = () => {
    const state = notifyPermission()
    lines.forEach((line) => {
      line.hidden = !box.checked || line.dataset.notifyState !== state
    })
    // The verdict below belongs to the granted line, so it goes with it:
    // unticking the box must not leave a stale "Sent." standing on its own.
    if (!box.checked || state !== "granted") settle("")
  }

  // Ticking the box IS the user gesture, so ask right there rather than after
  // the save: a member who saves and never sees a prompt has no way to tell
  // that the switch did not take effect on this machine.
  box.addEventListener("change", () => {
    if (box.checked) requestNotifyPermission()
    else apply()
  })

  // "Send a test notification". It goes the whole way round - through the
  // shell's socket to the server and back - so it answers the question the
  // status line above cannot: will something actually appear on THIS machine.
  // Permission granted is only the last link; the socket has to be up and the
  // operating system has to draw the thing.
  //
  // Which is why the button waits for an answer rather than assuming one. The
  // hook says `vutuv:notify-shown` the moment it really constructs a popup; if
  // nothing comes back in a few seconds the member is told so, instead of being
  // left to decide for themselves whether a popup they may simply have missed
  // was ever raised.
  window.addEventListener("vutuv:notify-shown", () => settle(note && note.dataset.sent))

  // Wired per instance rather than at the document level like Allow above,
  // because unlike Allow this button has state to keep: the timer and the
  // verdict line belong to this card.
  status.addEventListener("click", (event) => {
    if (!event.target.closest("[data-notify-test]")) return
    settle("")
    window.dispatchEvent(new CustomEvent("vutuv:notify-test"))
    waiting = setTimeout(() => settle(note && note.dataset.silent), 4000)
  })

  window.addEventListener("vutuv:notify-permission", apply)
  apply()
}

function setupBrowserNotifications() {
  document.querySelectorAll("[data-browser-notifications]").forEach(wireBrowserNotifications)
}
onReady(setupBrowserNotifications)

// Live character counter for a length-capped text field (the profile Tagline,
// see user/edit.html.heex). A [data-char-counter] wrapper with data-max holds a
// [data-char-count-input] field and a [data-char-count-readout] showing
// "N/max characters"; as the writer types we update the number and flip the
// readout to its over-limit state (red, ⚠ instead of ✓) so they can tell at a
// glance whether they trimmed enough before submitting. Server-side
// validate_length stays the source of truth — this only spares a round-trip.
// Counts code points (not UTF-16 units) so an emoji or astral char reads as one.
function wireCharCounter(wrap) {
  if (!once(wrap, "charCounter")) return
  const input = wrap.querySelector("[data-char-count-input]")
  const readout = wrap.querySelector("[data-char-count-readout]")
  const output = wrap.querySelector("[data-char-count]")
  const ok = wrap.querySelector("[data-char-ok]")
  const over = wrap.querySelector("[data-char-over]")
  const max = parseInt(wrap.dataset.max, 10)
  if (!input || !readout || !output || !max) return

  const update = () => {
    const used = [...input.value].length
    const isOver = used > max
    output.textContent = used
    readout.dataset.over = isOver ? "true" : "false"
    if (ok) ok.classList.toggle("hidden", isOver)
    if (over) over.classList.toggle("hidden", !isOver)
  }

  input.addEventListener("input", update)
  update()
}

function setupCharCounters() {
  document.querySelectorAll("[data-char-counter]").forEach(wireCharCounter)
}
onReady(setupCharCounters)

// The PIN countdown on the sign-up PIN screen (VutuvWeb.UI.pin_time_left/1 plus
// the [data-pin-live] / [data-pin-expired] blocks in
// page/pin_new_registration.html.heex). A PIN is good for 30 minutes; the
// server renders the remaining seconds and the four translated sentences, this
// ticks them down and, at zero, swaps every live block on the page for its
// expired counterpart. Every block, not one wrapper's worth: the swap spans the
// hero panel as well as the form card, since a hero still saying "check your
// inbox" beside a card announcing the PIN is dead is a page arguing with
// itself.
//
// Three deliberate details. The clock is anchored to the browser's OWN Date.now()
// at load rather than to an absolute server stamp, so a device whose clock runs
// fast cannot blank a form that is still perfectly good. Every tick recomputes
// from that anchor instead of decrementing a counter, so a backgrounded tab
// (whose timers are throttled to about one a minute) is simply correct again on
// return rather than minutes behind. And the text is only written when it
// actually changes, which for all but the last minute is once every 60 ticks.
function pinTimeLeftText(el, seconds) {
  const d = el.dataset
  if (seconds >= 60) {
    const minutes = Math.ceil(seconds / 60)
    return minutes === 1
      ? d.labelMinuteOne
      : d.labelMinuteOther.replace("{n}", String(minutes))
  }
  return seconds === 1 ? d.labelSecondOne : d.labelSecondOther.replace("{n}", String(seconds))
}

function setupPinCountdown() {
  const line = document.querySelector("[data-pin-time-left]")
  if (!line || !once(line, "pinCountdown")) return

  const total = parseInt(line.dataset.pinSecondsLeft, 10)
  // No deadline in the cookie (a legacy one, mid-deploy): the server sentence
  // stands as it is rather than counting down from a number we invented.
  if (!Number.isFinite(total)) return

  const live = document.querySelectorAll("[data-pin-live]")
  const expired = document.querySelectorAll("[data-pin-expired]")
  const deadline = Date.now() + total * 1000
  let timer = null

  const expire = () => {
    if (timer) clearInterval(timer)
    if (live.length === 0 || expired.length === 0) return
    live.forEach((el) => (el.hidden = true))
    expired.forEach((el) => (el.hidden = false))
    // The field they were typing into has just gone; put them at the top of
    // what replaced it, instead of leaving the caret on a removed input. An
    // aria-live region would not carry this: it announces content changes, not
    // a sibling quietly being hidden.
    expired[0].focus()
  }

  const tick = () => {
    const left = Math.round((deadline - Date.now()) / 1000)
    if (left <= 0) {
      expire()
      return
    }
    const text = pinTimeLeftText(line, left)
    if (line.textContent !== text) line.textContent = text
  }

  timer = setInterval(tick, 1000)
  tick()
}
onReady(setupPinCountdown)

// The tag pill box (VutuvWeb.UI.tag_input/1) on classic controller pages — the
// sign-up landing page and the invitation form. Inside a LiveView the same
// element carries phx-hook="TagInput" and is enhanced there instead;
// enhanceTagInput is idempotent, so whichever arrives first wins and the other
// finds the box already built.
function setupTagInputs() {
  document.querySelectorAll("[data-tag-input]").forEach(enhanceTagInput)
}
onReady(setupTagInputs)

// Reveal the "Jobsuche" details panel only once an employment status is chosen
// (issue #928, see user/edit.html.heex). A member who leaves the status at "Not
// open to work" should see one clean control; the panel ([data-jobsearch-details]
// -- availability visibility + salary expectation, server-rendered hidden when
// no status is set) appears as soon as they pick "Open to offers" / "Looking for
// a job" and hides again when they clear it. Plain <div> wrappers, so toggling
// `hidden` alone governs display (no competing display utility). With JS off the
// server-side state stands and the panel surfaces after the first save.
function wireEmploymentVisibility(select) {
  if (!once(select, "employmentVisibility")) return
  const wrap = select
    .closest("[data-employment-status-field]")
    ?.querySelector("[data-jobsearch-details]")
  if (!wrap) return

  const sync = () => wrap.classList.toggle("hidden", select.value === "")
  select.addEventListener("change", sync)
  sync()
}

function setupEmploymentVisibility() {
  document
    .querySelectorAll("[data-employment-status-select]")
    .forEach(wireEmploymentVisibility)
}
onReady(setupEmploymentVisibility)

// The Arbeitszeugnis form's publish confirmation (see job_reference/
// form_content.html.heex). Publishing a Zeugnis hands a former employer's
// graded judgement of a person to anyone, including search engines, and cannot
// be taken back -- so the changeset demands a separate tick on the
// private->public step. That tick is the one deliberate speed bump on this
// form, and it was being spent on every save: an unticked confirmation box
// under a form that saves fine reads as an unmet requirement, and after a few
// of those nobody reads it on the save where it matters. So it appears with
// the decision it confirms and goes away with it.
// Same shape as the employment panel above: a plain wrapper whose only display
// governor is `hidden` (issue #880), server-rendered visible, so with JS off
// the box is simply always there to tick.
function wirePublicConsent(toggle) {
  if (!once(toggle, "publicConsent")) return
  const wrap = toggle.closest("[data-public-visibility]")?.querySelector("[data-public-consent]")
  if (!wrap) return

  const sync = () => wrap.classList.toggle("hidden", !toggle.checked)
  toggle.addEventListener("change", sync)
  sync()
}

// The file drop zone on a classic form (the Arbeitszeugnis upload, see
// job_reference/form_content.html.heex). Two things the native input cannot do:
// take a dragged file, and say something before the upload starts.
//
// The size check is the second one. The cap is enforced server-side by
// JobReferenceDocument.validate/1 and always will be -- this is not that check,
// it is the difference between hearing "too large" now and hearing it after
// pushing 40 MB up a phone's uplink. Both numbers come from the same place
// (`data-upload-max`, written from JobReferenceDocument.max_size/0), so they
// cannot drift.
//
// Clicking is NOT wired here: the <label for> already opens the picker, so the
// zone works with JavaScript off. Only dropping and the check are added.
function wireUploadDrop(zone) {
  if (!once(zone, "uploadDrop")) return

  const input = zone.querySelector("input[type=file]")
  const nameEl = zone.querySelector("[data-upload-name]")
  const errorEl = zone.parentElement?.querySelector("[data-upload-error]")
  const max = parseInt(zone.dataset.uploadMax || "0", 10)
  if (!input) return

  const showError = message => {
    if (!errorEl) return
    errorEl.textContent = message || ""
    errorEl.hidden = !message
  }

  const accept = file => {
    if (max && file.size > max) {
      // Refused before it is staged, so a submit cannot carry it: clearing the
      // input is what makes the message true.
      input.value = ""
      if (nameEl) nameEl.textContent = ""
      showError(zone.dataset.uploadTooLarge)
      return false
    }
    if (nameEl) nameEl.textContent = file.name
    showError(null)
    return true
  }

  input.addEventListener("change", () => {
    const file = input.files && input.files[0]
    if (file) accept(file)
  })

  // dragover must be prevented too, or the browser keeps its "not allowed"
  // cursor and never fires the drop.
  ;["dragenter", "dragover"].forEach(name =>
    zone.addEventListener(name, event => {
      event.preventDefault()
      zone.classList.add("is-dragover")
    })
  )
  ;["dragleave", "dragend"].forEach(name =>
    zone.addEventListener(name, () => zone.classList.remove("is-dragover"))
  )

  zone.addEventListener("drop", event => {
    event.preventDefault()
    zone.classList.remove("is-dragover")

    const file = event.dataTransfer?.files?.[0]
    if (!file || !accept(file)) return

    // A file input's `files` is read-only except through a DataTransfer, which
    // is the whole reason this handoff looks indirect.
    const transfer = new DataTransfer()
    transfer.items.add(file)
    input.files = transfer.files
  })
}

function setupUploadDrops() {
  document.querySelectorAll("[data-upload-drop]").forEach(wireUploadDrop)
}
onReady(setupUploadDrops)

function setupPublicConsent() {
  document
    .querySelectorAll('[data-public-visibility] input[name="job_reference[public?]"]')
    .forEach(wirePublicConsent)
}
onReady(setupPublicConsent)

// The profile editor's "Remove date of birth" control (see user/edit.html.heex).
// The native <input type="date"> gives no clear affordance in some browsers
// (Safari on macOS renders spinners with no ✕), so a member could set a birthday
// but never remove it (issue #901). The trigger is a real submit
// (name=clear_birthdate) so it still works with JS off; here we intercept it and
// ask "Are you sure?" in a designed dialog first, then submit for real. We use
// form.requestSubmit(trigger) so the trigger's name/value ride along and the
// controller nils the date even though the date input still carries its old
// value (form.submit() would drop the submitter, and thus clear_birthdate).
function setupBirthdayRemove() {
  const trigger = document.querySelector("[data-birthday-remove]")
  const modal = document.getElementById("birthday-remove-modal")
  if (!trigger || !modal || !once(modal, "birthdayRemove")) return

  const confirmBtn = modal.querySelector("[data-birthday-remove-confirm]")
  let lastFocused = null

  const open = () => {
    lastFocused = document.activeElement
    modal.classList.remove("hidden")
    confirmBtn?.focus()
  }
  const close = () => {
    modal.classList.add("hidden")
    if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus()
    lastFocused = null
  }

  trigger.addEventListener("click", (e) => {
    e.preventDefault()
    open()
  })

  confirmBtn?.addEventListener("click", () => {
    const form = trigger.form
    close()
    if (form && form.requestSubmit) {
      form.requestSubmit(trigger)
    } else if (form) {
      // Fallback for browsers without requestSubmit: carry clear_birthdate by hand.
      const hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = trigger.name
      hidden.value = trigger.value
      form.appendChild(hidden)
      form.submit()
    }
  })

  // Cancel button and backdrop dismiss without removing anything.
  modal.addEventListener("click", (e) => {
    if (
      e.target.closest("[data-birthday-remove-cancel]") ||
      e.target.hasAttribute("data-birthday-remove-backdrop")
    ) {
      close()
    }
  })

  // Esc closes; Tab cycles between the two buttons so focus can't slip behind
  // the modal. (The keyboard-shortcuts handler also swallows shortcuts while a
  // [data-block-shortcuts] modal is open, so "n"/"g …" don't fire behind it.)
  modal.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      e.preventDefault()
      close()
      return
    }
    if (e.key !== "Tab") return
    const buttons = modal.querySelectorAll("button")
    if (buttons.length === 0) return
    const first = buttons[0]
    const last = buttons[buttons.length - 1]
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  })
}
onReady(setupBirthdayRemove)

// The Fediverse take-part switch (see settings/fediverse.html.heex) asks before
// it flips, in either direction: taking part means posts leave vutuv for good,
// and leaving asks the other servers to forget an account they may then not show
// again. Both are unreversible, so the submit is intercepted and the matching
// dialog opened; its confirm button fills the `fediverse_ack` field and submits
// for real. With JS off nothing here runs and the plain submit lands on the
// server-side confirmation page, which asks the same question — the switch can
// never flip unacknowledged.
function setupFediverseConsent() {
  const form = document.getElementById("fediverse-form")
  if (!form || !once(form, "fediverseConsent")) return

  const checkbox = form.querySelector("[data-fediverse-switch]")
  const ack = form.querySelector("[data-fediverse-ack]")
  const modals = {
    true: document.getElementById("fediverse-consent-on"),
    false: document.getElementById("fediverse-consent-off"),
  }
  if (!checkbox || !ack) return

  let openModal = null
  let lastFocused = null

  const close = () => {
    openModal?.classList.add("hidden")
    openModal = null
    if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus()
    lastFocused = null
  }

  const open = (modal) => {
    lastFocused = document.activeElement
    openModal = modal
    modal.classList.remove("hidden")
    modal.querySelector("[data-fediverse-consent-confirm]")?.focus()
  }

  form.addEventListener("submit", (e) => {
    // Only the switch itself needs acknowledging; saving the other settings on
    // this page must not raise a dialog about a change nobody made.
    if (ack.value === "1" || checkbox.checked === checkbox.defaultChecked) return

    const modal = modals[String(checkbox.checked)]
    if (!modal) return

    e.preventDefault()
    open(modal)
  })

  Object.values(modals).forEach((modal) => {
    if (!modal) return

    modal.addEventListener("click", (e) => {
      if (e.target.closest("[data-fediverse-consent-confirm]")) {
        ack.value = "1"
        close()
        form.requestSubmit ? form.requestSubmit() : form.submit()
        return
      }

      if (
        e.target.closest("[data-fediverse-consent-cancel]") ||
        e.target.hasAttribute("data-fediverse-consent-backdrop")
      ) {
        close()
      }
    })

    // Esc closes; Tab cycles inside the dialog so focus can't slip behind it.
    modal.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        close()
        return
      }
      if (e.key !== "Tab") return
      const buttons = modal.querySelectorAll("button")
      if (buttons.length === 0) return
      const first = buttons[0]
      const last = buttons[buttons.length - 1]
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault()
        first.focus()
      }
    })
  })
}
onReady(setupFediverseConsent)

// The ad banner (layout strip between navigation and content, see
// VutuvWeb.Plug.AdBanner) disappears on its own after two minutes: fade out,
// then drop the node. Its ✕ removes it immediately AND keeps ads away for
// the rest of the (Berlin) day: the cookie value is the day stamped onto the
// button by the server, which the plug compares against its own "today".
// Classic controller pages only, so plain JS suffices.
onReady(() => {
  const ad = document.querySelector("[data-ad-banner]")
  if (!ad || !once(ad, "adBanner")) return

  const close = ad.querySelector("[data-ad-close]")
  if (close) {
    close.addEventListener("click", () => {
      document.cookie = `vutuv_ad_dismissed=${close.dataset.adDay}; path=/; max-age=86400; samesite=lax`
      ad.remove()
    })
  }

  setTimeout(() => {
    ad.style.transition = "opacity 0.5s ease"
    ad.style.opacity = "0"
    setTimeout(() => ad.remove(), 500)
  }, 120000)
})

// Card ⋯ menus (<details data-menu>, see VutuvWeb.UI.card_menu): the native
// <details> toggle does everything except light-dismiss, so close any open
// menu when clicking outside it or pressing Escape. Event delegation keeps
// this working for menus added to the DOM later.
document.addEventListener("click", (e) => {
  document.querySelectorAll("details[data-menu][open]").forEach((menu) => {
    if (!menu.contains(e.target)) menu.removeAttribute("open")
  })
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  document
    .querySelectorAll("details[data-menu][open]")
    .forEach((menu) => menu.removeAttribute("open"))
})

// Multipart enctype fallback (issue #1227). One member's Safari submitted the
// multipart profile form with a declared boundary but a zero-byte body on
// every attempt (Content-Length: 0 in the nginx capture), while every
// urlencoded form from the same browser worked: WebKit builds a multipart body
// as a stream it cannot always replay, a urlencoded body is in-memory and
// survives. Multipart only buys file transport, so when no file is actually
// selected the form downgrades to urlencoded at submit time — and the empty
// file inputs are disabled for that one submission, so the request carries the
// exact params a fileless multipart submit produces. Capture phase, before the
// browser serializes the form; LiveView forms own their submits and are
// skipped. The re-enable runs a tick later: the entry list is built
// synchronously after dispatch, and a submit some other handler cancels must
// not leave the inputs disabled.
function multipartEnctypeFallback(e) {
  const form = e.target
  if (!(form instanceof HTMLFormElement) || form.hasAttribute("phx-submit")) return

  const wasMultipart =
    form.enctype === "multipart/form-data" || form.dataset.multipartForm === "1"
  if (!wasMultipart) return
  form.dataset.multipartForm = "1"

  const fileInputs = [...form.querySelectorAll("input[type=file]")]
  const hasFiles = fileInputs.some((input) => input.files && input.files.length > 0)
  form.enctype = hasFiles ? "multipart/form-data" : "application/x-www-form-urlencoded"
  if (hasFiles) return

  const disabled = fileInputs.filter((input) => !input.disabled)
  disabled.forEach((input) => (input.disabled = true))
  setTimeout(() => disabled.forEach((input) => (input.disabled = false)), 0)
}

document.addEventListener("submit", multipartEnctypeFallback, true)

// Avatar fallback. A user's stored avatar file can be missing — a legacy row
// whose image was never imported, a failed upload, a derived version not yet
// regenerated — so the <img> 404s and the browser draws a broken-image icon.
// Swap any avatar that fails to load to the same neutral silhouette a user with
// no avatar already shows, so the lists never show a broken image. Scoped to
// img[data-avatar] (set by VutuvWeb.UI.avatar/1 and user/card_list) so post
// images, link thumbnails and screenshots keep their own fallbacks. Two notes:
// `error` events don't bubble, so we listen in the capture phase; and the swap
// runs once so a fallback that itself fails can't loop.
//
// Keep NEUTRAL_AVATAR identical to `Vutuv.Avatar`'s @default_avatar (the SVG a
// nil-avatar user renders) so a broken avatar is visually indistinguishable.
const NEUTRAL_AVATAR =
  "data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

document.addEventListener(
  "error",
  (e) => {
    const img = e.target
    if (
      img.tagName !== "IMG" ||
      !img.hasAttribute("data-avatar") ||
      img.dataset.avatarFallbackApplied
    )
      return
    img.dataset.avatarFallbackApplied = "1"
    img.src = NEUTRAL_AVATAR
  },
  true
)
