// The card behind a `@user@host` mention.
//
// The mention stays a link to that server (`VutuvWeb.Markdown`), and this
// intercepts the plain left click on it to open a small card instead: who that
// account is, one Follow button, and the two ways onward (their page here, the
// original out there). Every other way of following the link is left alone —
// a modified click, a middle click, "copy link address", a visitor who is not
// signed in, and a page whose JavaScript never arrived all get today's
// behaviour, because the `href` is still the whole truth of that anchor.
//
// It reaches every rendered `@user@host`, which is more than posts: a chat
// message and a work-experience description run through the same renderer, and
// the same reader wants the same thing there.
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
import { request } from "./util"

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
  window.addEventListener("scroll", reposition, { passive: true, capture: true })
  window.addEventListener("resize", reposition, { passive: true })
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
async function fetchCard(url, method) {
  const resp = await request(url, {
    method,
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `address=${encodeURIComponent(anchor.dataset.remoteActor)}`,
  })
  if (!resp.ok) throw new Error(`actor card ${resp.status}`)
  return resp.text()
}

// The mention's own link, taken as soon as the enhancement gives up: a session
// that expired, a server that answered with something else. `window.open`
// keeps the new tab the anchor asks for; a blocked popup falls back to this
// tab, which is still where the reader wanted to go.
function followTheLink(link) {
  const href = link.getAttribute("href")
  if (!href) return
  if (!window.open(href, "_blank", "noopener,noreferrer")) window.location.assign(href)
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
    panel.innerHTML = await fetchCard(CARD_URL, "POST")
    place()
    takeFocus()
  } catch (_e) {
    close()
    followTheLink(link)
  }
}

// Follow / unfollow from inside the card. The answer is the whole card again,
// so the button's next state, the status pill and any refusal all arrive
// together and this side never has to guess what the act meant.
async function act(button) {
  button.disabled = true

  const method = button.dataset.actorAct === "follow" ? "POST" : "DELETE"

  try {
    panel.innerHTML = await fetchCard(`${CARD_URL}/follow`, method)
    place()
    takeFocus()
  } catch (_e) {
    // Leave the card as it stands rather than inventing an outcome; the button
    // comes back, so the reader can try again.
    button.disabled = false
  }
}

document.addEventListener("click", (e) => {
  const link = e.target.closest("a[data-remote-actor]")

  if (isOpen()) {
    if (panel.contains(e.target)) {
      if (e.target.closest("[data-actor-card-close]")) {
        e.preventDefault()
        return close()
      }

      const button = e.target.closest("[data-actor-act]")
      if (button) {
        e.preventDefault()
        return act(button)
      }

      // A link inside the card (their page here, the original out there):
      // that is a destination, not a control. Let it navigate.
      return
    }

    // A click anywhere else closes it — and on the mention it belongs to, that
    // is the whole gesture: pressing the word again puts the card away.
    const sameMention = anchor === link
    close()
    if (sameMention) return e.preventDefault()
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

  e.preventDefault()
  open(link)
})

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") close()
})
