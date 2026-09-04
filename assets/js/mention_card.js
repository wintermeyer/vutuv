// The card behind a remote handle.
//
// The handle keeps its own link, and this intercepts the plain left click on it
// to open a small card instead: who that account is, one Follow button, and the
// two ways onward (their page here, the original out there). Every other way of
// following the link is left alone — a modified click, a middle click, "copy
// link address", a visitor who is not signed in, and a page whose JavaScript
// never arrived all get today's behaviour, because the `href` is still the
// whole truth of that anchor.
//
// It binds to `a[data-remote-actor]`, wherever that is written. Two places
// write it. A `@user@host` inside rendered text (`VutuvWeb.Markdown`), which is
// more than posts — a chat message and a work-experience description run
// through the same renderer. And every other remote account the app draws,
// through `VutuvWeb.FediverseComponents.remote_actor_link/3`, whose docstring
// names its callers. Wherever a reader meets somebody from another network they
// are asking the same question about the same account, and until this they got
// either a trip to a server they have no account on or a page they had to come
// back from. The two writers lead different places when the card cannot open,
// which is why `followTheLink` reads the target rather than assuming one.
//
// The card's markup comes from the server on every act
// (`VutuvWeb.RemoteActorCardController`), so no sentence about a follow, a
// refusal or an hourly budget is written twice — this file positions a box and
// swaps HTML into it, and knows nothing about what is inside.
//
// The panel is appended to `document.body`, deliberately outside every
// LiveView root: a patch of the page underneath must not be able to take the
// open card with it. That is also why the fragment carries no `phx-` link and
// no fixed id (see the template).
import { copyText, request, revealPreviewClamp } from "./util"

const CARD_URL = "/system/fediverse/actor_card"

// Below this the card is a sheet at the bottom of the screen rather than a box
// under the word: a 20rem popover anchored to a word in a paragraph has
// nowhere to go on a 360px phone, and a sheet puts its buttons where a thumb
// already is. In `rem` like the other panels' breakpoint, so a reader who
// enlarged their default font gets the sheet at the same point the CSS does.
const SHEET = window.matchMedia("(width < 40rem)")

// Room the card keeps from the window edge, and from the mention it belongs to.
const EDGE = 8
const GAP = 6

// No words: the sentences are the server's to write, and an outline that says
// nothing says it in every language. `.skeleton` is the breathing outline every
// other not-yet-arrived thing here wears.
const SKELETON = `<div class="actor-card__skeleton" aria-busy="true" aria-hidden="true">
  <span class="skeleton actor-card__skeleton-tile"></span>
  <span class="actor-card__skeleton-lines">
    <i class="skeleton"></i><i class="skeleton"></i><i class="skeleton"></i>
  </span>
</div>`

let panel = null
let backdrop = null
let anchor = null
let queued = false

const isOpen = () => anchor !== null

function ensurePanel() {
  if (panel) return

  backdrop = document.createElement("div")
  backdrop.className = "actor-card__backdrop"
  backdrop.hidden = true
  backdrop.addEventListener("click", close)

  panel = document.createElement("div")
  panel.className = "actor-card"
  panel.setAttribute("role", "dialog")
  panel.hidden = true

  document.body.append(backdrop, panel)

  // Only from here on: a page where no mention is ever clicked should not carry
  // a capture-phase scroll listener, which every scrolling container on it
  // would otherwise feed.
  window.addEventListener("scroll", onScroll, { passive: true, capture: true })
  window.addEventListener("resize", reposition, { passive: true })
  // The self-description's lid is a native `<details>`, so opening it costs this
  // file nothing — except that the card just changed height and may no longer
  // fit below the word it belongs to. On the panel and not the document, for
  // the same reason as the two above: every ⋯ menu and sensitive-image lid on
  // the page is a `<details>` this has no business hearing about. Capture phase,
  // because `toggle` does not bubble and so never reaches an ancestor otherwise.
  panel.addEventListener("toggle", reposition, { capture: true })
}

function close() {
  if (!isOpen()) return
  panel.hidden = true
  panel.innerHTML = ""
  backdrop.hidden = true
  anchor.removeAttribute("aria-expanded")
  // Only take the focus back when it is still inside the card — a reader who
  // has clicked away has already said where they want to be.
  if (panel.contains(document.activeElement)) anchor.focus()
  anchor = null
}

// Scroll fires more than once per frame, and `place()` measures and then
// writes; coalesce to one measure-and-write per paint (the shape
// `scroll_top_tab.js` uses for the same reason).
function reposition() {
  if (queued || !isOpen() || SHEET.matches) return
  queued = true
  window.requestAnimationFrame(() => {
    queued = false
    place()
  })
}

// Scrolling inside the card is not the card moving: the opened
// self-description is a scroll box of its own, and following its every frame
// would spend two forced layout reads to answer that the mention has not
// budged. The page's own scroll targets the document, which is not in here.
//
// `instanceof Node` because `contains` takes a Node and nothing else: the page
// scroll arrives with the document as its target, but anything dispatching one
// at `window` would otherwise throw in here and take the repositioning with it.
function onScroll(e) {
  if (e.target instanceof Node && panel.contains(e.target)) return
  reposition()
}

// Under the mention, and inside the window: flipped above the word when there
// is no room below, and shifted sideways rather than hanging off an edge. The
// anchor's rect is viewport-relative and so is `position: fixed`, so scrolling
// only has to re-run this, not correct for it.
function place() {
  if (!isOpen()) return
  if (!anchor.isConnected) return close()

  if (SHEET.matches) {
    panel.classList.add("actor-card--sheet")
    panel.style.left = panel.style.top = ""
    return
  }

  panel.classList.remove("actor-card--sheet")

  const at = anchor.getBoundingClientRect()

  // The mention scrolled out of the window: the card would point at nothing.
  if (at.bottom < 0 || at.top > window.innerHeight) return close()

  const box = panel.getBoundingClientRect()
  const below = at.bottom + GAP
  const top = below + box.height > window.innerHeight - EDGE ? at.top - box.height - GAP : below

  panel.style.left = `${Math.max(EDGE, Math.min(at.left, window.innerWidth - box.width - EDGE))}px`
  panel.style.top = `${Math.max(EDGE, top)}px`
}

// The reader asked for this box, so the keyboard follows them into it — and
// keeps up when the card is replaced, since the button they just pressed is
// gone with the old fragment and focus would otherwise fall back to the body.
// The Follow button first, not whatever comes first in the markup: the × leads
// the fragment (it belongs in the corner), and dropping a keyboard reader on
// "Close" answers a question they did not ask.
function takeFocus() {
  const first = panel.querySelector("[data-actor-act]") || panel.querySelector("button, a")
  if (first) first.focus({ preventScroll: true })
}

// One shape for the three calls (open, follow, unfollow): a form-encoded
// address, and the whole card back as HTML.
//
// `innerHTML` with that answer is deliberate and safe: it is our own
// same-origin endpoint rendering a HEEx template, so everything a remote server
// supplied — a display name, a self-description — is escaped there, on the side
// that knows what is markup and what is text. Building the card here instead
// would mean writing its sentences twice, once in German.
async function fetchCard(url, method, extra = "") {
  const resp = await request(url, {
    method,
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `address=${encodeURIComponent(anchor.dataset.remoteActor)}${state()}${extra}`,
  })
  if (!resp.ok) throw new Error(`actor card ${resp.status}`)
  return resp.text()
}

// The self-description's lid, which two things ask about: the measurement below
// and `state()`, which sends its position back with every act.
const bioLid = () => panel.querySelector("[data-remote-summary]")

// A fresh card in the panel, and everything that has to happen to it before the
// reader sees it — in one place, because the three steps are one act and this
// runs from both `open` and `act`.
//
// The measuring is the card's own to ask for. The self-description arrives
// clamped to three lines, and whether there is anything behind that lid depends
// on the reader's window and font; `revealPreviewClamp` and the
// `is-measured` / `is-clamped` rules already answer that for the account page,
// but nothing sweeps a fragment swapped into a body-level panel. It runs before
// `place()`, since hiding a useless lid changes the height that decides where
// the card sits.
//
// Unmeasured means the lid shows, so this can only ever take away a control
// that does nothing. An OPEN lid is left alone: its clamped copy is hidden and
// would measure as uncut, taking away the "Show less" the reader needs —
// `revealPreviewClamp` bails on that by itself.
function paint(html) {
  panel.innerHTML = html

  const bio = bioLid()
  if (bio) revealPreviewClamp(bio)

  place()
  takeFocus()
}

// What the reader has in front of them, sent with every request: which post is
// open behind the card, and whether they have opened its drawer of older posts.
//
// `context` is the post the handle they pressed sits inside
// (`article[data-remote-post]`, written by the remote post card). The card
// quotes the account's newest posts, and opened from a post's author line that
// newest post is the one on the screen underneath it — so the server is told
// which one to skip.
//
// `expanded` is read back out of the card's own DOM. Every act replaces the
// whole fragment, so anything this side does not send back is lost on the next
// press: without it, opening the drawer and then pressing Follow folds it away
// again — the same "the card contradicts itself over one click" the context
// param exists to prevent. Both are read fresh on every request rather than
// remembered, which costs one `closest` and one `querySelector` and cannot go
// stale.
function state() {
  const post = anchor.closest("[data-remote-post]")
  const older = panel.querySelector("[data-actor-more-posts]")
  const bio = bioLid()

  return (
    (post ? `&context=${encodeURIComponent(post.dataset.remotePost)}` : "") +
    (older && !older.hidden ? "&expanded=1" : "") +
    (bio && bio.open ? "&bio=1" : "")
  )
}

// What each control on the card sends. The card is the only thing that knows
// which way round a mute currently is and it re-renders on every act, so the
// two mutes are toggles with a scope rather than a target state — this side
// stays the dumb thing that swaps HTML.
const ACTS = {
  follow: { path: "/follow", method: "POST" },
  unfollow: { path: "/follow", method: "DELETE" },
  "mute-account": { path: "/mute", method: "POST", extra: "&scope=account" },
  "mute-host": { path: "/mute", method: "POST", extra: "&scope=host" },
}

// The anchor's own link, taken as soon as the enhancement gives up: a session
// that expired, a server that answered with something else. Where it leads is
// the anchor's business and not this file's — a mention leaves for the other
// server in a new tab, a card header's handle leads to that account's page here
// and belongs in this one — so the anchor's target decides. A blocked popup
// falls back to this tab, which is still where the reader wanted to go.
function followTheLink(link) {
  const href = link.getAttribute("href")
  if (!href) return
  if (link.target === "_blank" && window.open(href, "_blank", "noopener,noreferrer")) return
  window.location.assign(href)
}

// The click is ours, and saying so takes both halves. `preventDefault` alone is
// enough for a mention, which is a plain anchor — but a card header's handle is
// a `<.link navigate>`, and LiveView's own nav listener on `window` never asks
// whether the default was prevented: it reads `data-phx-link` and navigates, so
// the card would open and the page would leave underneath it in one gesture.
// Stopping the bubble at `document` keeps the event from reaching that listener
// at all, and only ever on the presses this file has taken over.
//
// The one thing this also swallows is `phx-click-away`, which LiveView dispatches
// from the same window listener. The app uses none today; the day a page with
// remote cards does, this is where it goes quiet.
function keepTheClick(e) {
  e.preventDefault()
  e.stopPropagation()
}

async function open(link) {
  ensurePanel()
  anchor = link
  link.setAttribute("aria-expanded", "true")

  panel.innerHTML = SKELETON
  panel.hidden = false
  backdrop.hidden = !SHEET.matches
  place()

  try {
    paint(await fetchCard(CARD_URL, "POST"))
  } catch (_e) {
    close()
    followTheLink(link)
  }
}

// Any act from inside the card. The answer is the whole card again, so the
// button's next state, the mute state and any refusal all arrive together and
// this side never has to guess what the act meant.
async function act(button) {
  const spec = ACTS[button.dataset.actorAct]
  if (!spec) return

  button.disabled = true

  try {
    paint(await fetchCard(`${CARD_URL}${spec.path}`, spec.method, spec.extra || ""))
  } catch (_e) {
    // Leave the card as it stands rather than inventing an outcome; the button
    // comes back, so the reader can try again.
    button.disabled = false
  }
}

// The hover swap is the pointer's confirmation step: the follow button reads as
// the state and only becomes "Unfollow" once the pointer is on it, so the act is
// never what a stray click lands on. A touch screen has no such moment, so the
// first press asks and the second one acts.
//
// Worth the two presses because the two mistakes are not the same size: an
// unfollow is one press away from being undone, while a withdrawn request has
// to be approved by hand on the other side again and may take days or never
// come back. The wording is the server's (`data-actor-confirm`) — this file
// writes no sentences.
//
// `matchMedia("(hover: hover)")` and not `SHEET`: the question is whether this
// input device can hover, which is not the same as how wide the window is. A
// touch laptop asked to open the card in a narrow window gets a sheet and can
// still hover; a stylus tablet at 900px gets a popover and cannot. The same
// query gates the CSS half, so the two cannot disagree about which device this
// is.
const CAN_HOVER = window.matchMedia("(hover: hover)")

function armed(button) {
  const asks = button.querySelector("[data-actor-state-confirm]")
  if (!asks || CAN_HOVER.matches || button.classList.contains("is-confirming")) return false

  button.classList.add("is-confirming")
  return true
}

// The overflow: the mutes and the address, behind one ⋯. Closing it also takes
// back an armed follow button, so the two never sit waiting at the same time.
function closeMenu() {
  if (!isOpen()) return

  const menu = panel.querySelector("[data-actor-card-menu]")
  if (menu) menu.hidden = true

  const more = panel.querySelector("[data-actor-menu]")
  if (more) more.setAttribute("aria-expanded", "false")

  panel
    .querySelectorAll(".is-confirming")
    .forEach((button) => button.classList.remove("is-confirming"))
}

function toggleMenu(button) {
  const menu = panel.querySelector("[data-actor-card-menu]")
  if (!menu) return

  const opening = menu.hidden
  closeMenu()
  menu.hidden = !opening
  button.setAttribute("aria-expanded", String(opening))
  // In the popover the menu floats over the card's lower edge, so nothing
  // moves; in the sheet it opens in the flow and the sheet grows upward from
  // the bottom edge, which `place()` has nothing to do with. Either way the
  // card must not end up hanging off the top of the window.
  place()
}

// The older posts, folded away under the newest one. They are already in the
// fragment — four short strings the server had in hand — so this opens a drawer
// rather than asking for anything, and `place()` re-runs because the card just
// grew and may no longer fit below the word it belongs to.
//
// Which label the button wears is CSS's business, like the follow button's
// three: this adds a class and writes no words.
function togglePosts(button) {
  const older = panel.querySelector("[data-actor-more-posts]")
  if (!older) return

  const opening = older.hidden
  older.hidden = !opening
  button.classList.toggle("is-open", opening)
  button.setAttribute("aria-expanded", String(opening))
  place()
}

// The address, for pasting into another client. Purely local: nothing here is a
// question for the server. The confirmation is the button's own label for a
// moment — a toast for something this small would outweigh it — and the word is
// the server's (`data-actor-copied`).
//
// `copyText` from util.js rather than `navigator.clipboard` directly: that one
// carries the fallback an installation without a secure context needs, and it
// is the same path the settings page's copy button takes.
async function copyAddress(button) {
  const address = button.dataset.actorCopy
  const said = button.dataset.actorCopied
  const label = button.querySelector("[data-actor-copy-label]")

  try {
    await copyText(address)
  } catch (_e) {
    // The copy really failed. Say nothing rather than claim it worked; the
    // address is on the card to select by hand.
    return
  }

  if (!said || !label) return

  const was = label.textContent
  label.textContent = said
  window.setTimeout(() => {
    if (label.isConnected) label.textContent = was
  }, 1500)
}

document.addEventListener("click", (e) => {
  const link = e.target.closest("a[data-remote-actor]")

  if (isOpen()) {
    if (panel.contains(e.target)) {
      if (e.target.closest("[data-actor-card-close]")) {
        e.preventDefault()
        return close()
      }

      const more = e.target.closest("[data-actor-menu]")
      if (more) {
        e.preventDefault()
        return toggleMenu(more)
      }

      const copy = e.target.closest("[data-actor-copy]")
      if (copy) {
        e.preventDefault()
        return copyAddress(copy)
      }

      const posts = e.target.closest("[data-actor-posts-toggle]")
      if (posts) {
        e.preventDefault()
        return togglePosts(posts)
      }

      const button = e.target.closest("[data-actor-act]")
      if (button) {
        e.preventDefault()
        if (armed(button)) return
        return act(button)
      }

      // A press anywhere else inside the card puts the overflow away — and
      // takes back a follow button that was waiting for its second press,
      // because "are you sure" that outlives the moment is a trap the next
      // press falls into.
      closeMenu()

      // A link inside the card (their page here, the original out there):
      // that is a destination, not a control. Let it navigate.
      return
    }

    // A click anywhere else closes it — and on the anchor it belongs to, that
    // is the whole gesture: pressing the word again puts the card away.
    const sameMention = anchor === link
    close()
    if (sameMention) return keepTheClick(e)
  }

  if (!link) return

  // Everything that is not a plain left click means "take me to that server",
  // and so does a click by anybody who is not signed in: the card is a follow
  // surface, and asking the server whether they may have one would cost a
  // request just to find out that they may not. The shell renders the account
  // menu for a signed-in reader on every page, dead render included, which is
  // the marker the keyboard shortcuts already read.
  if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  if (!document.querySelector("[data-account-menu]")) return

  keepTheClick(e)
  open(link)
})

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") close()
})

