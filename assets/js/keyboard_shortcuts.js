// Desktop-only keyboard shortcuts.
//
// The whole feature is gated on a desktop input profile ("(hover: hover) and
// (pointer: fine)") so it never fires on phones or tablets, where shortcuts
// make no sense and a stray keypress from an attached keyboard should not
// teleport the user. Shortcuts are also ignored while the user is typing in a
// field or holding a modifier (so Cmd/Ctrl combos keep working).
//
// A "?" opens a help overlay listing the shortcuts; the account menu carries a
// "Keyboard shortcuts" item that opens the same overlay (both wired here). "g"
// starts a Gmail-style two-key navigation sequence (g h, g f, …); "/" jumps to
// search, "n" focuses the feed composer, and "j" / "k" step through feed posts.
// Cross-page navigation is a plain location change so it works identically on
// classic controller pages and LiveView pages.

import { closeCardMenus, onReady } from "./util"

const DESKTOP = window.matchMedia("(hover: hover) and (pointer: fine)")

const SEQUENCE_WINDOW_MS = 1500

// A keydown that starts inside a shadow tree arrives at document retargeted to
// the shadow HOST, so `e.target` is that host's plain <div> and the isTyping()
// guard below waves it through — which is how "n", "/" and "?" got swallowed
// while typing into the Tidewave dev toolbar (it mounts into an open shadow
// root on every dev page and stops only pointer events at its host). vutuv
// itself uses no shadow DOM, so a retargeted keydown is by definition somebody
// else's widget: leave the key to it.
function fromForeignShadowRoot(e) {
  const path = e.composedPath?.()
  return !!path && path.length > 0 && path[0] !== e.target
}

function isTyping(el) {
  if (!el) return false
  const tag = el.tagName
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    el.isContentEditable
  )
}

// The logged-in chrome renders the account menu; its absence means logged out,
// so the member-only shortcuts (feed, messages, …) stay inert for visitors.
function loggedIn() {
  return !!document.querySelector("[data-account-menu]")
}

// The member's own profile path is rendered into the account menu's identity
// link; used by "g p".
function profilePath() {
  return document
    .querySelector("[data-account-menu] [data-self-profile]")
    ?.getAttribute("href")
}

function go(path) {
  if (path) window.location.assign(path)
}

// "n" (new post): focus this page's composer if it has one — /feed and the
// owner's own profile both do — otherwise jump to the feed and focus it on
// arrival (#compose). Returning false (no composer here) is what makes the
// handler navigate to the feed instead. Exported for
// the phone tab bar's Write tab (compose_tab.js), which asks the same question.
export function focusComposer() {
  if (!document.getElementById("composer-body")) return false
  revealAndFocusComposer()
  // Drop the hash so a later reload / back-button doesn't refocus out of the blue.
  if (location.hash === "#compose") {
    history.replaceState(null, "", location.pathname + location.search)
  }
  return true
}

// A node hidden with display:none has no box; that is how we tell the collapsed
// composer from a ready-to-focus textarea.
function isVisible(el) {
  return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)
}

// The composer starts collapsed (display:none) behind a "Write a post" button
// on both pages that host one, and focus() is a no-op on a display:none node,
// so click the reveal trigger first, then focus once it paints. The reveal is a LiveView
// round-trip, and on a cross-page arrival (#compose) the socket may still be
// joining, which swallows the first click; so retry the click each tick until
// the editor is actually visible, then focus. Reaching the click at all means
// the editor — and with it the panel it sits in — is still hidden, so this
// never pushes `open-composer` at an already-open composer. The trigger's own
// visibility is deliberately not asked: on the feed it is invisible on a phone
// (that line is desktop-only, the tab bar's Write tab does its job there) while
// on the profile it is not, and a hidden button still takes a click() anyway.
function revealAndFocusComposer(tries = 0) {
  const el = document.getElementById("composer-body")
  if (el && isVisible(el)) {
    el.focus()
    return
  }
  if (tries > 40) return
  document.getElementById("open-composer")?.click()
  setTimeout(() => revealAndFocusComposer(tries + 1), 50)
}

function focusComposerFromHash() {
  if (location.hash !== "#compose") return
  let tries = 0
  const attempt = () => {
    if (focusComposer() || ++tries > 20) return
    setTimeout(attempt, 100)
  }
  attempt()
}

// "j" / "k": step a highlight down / up the feed and scroll it into view. Only
// the feed page has #feed-posts, so they are inert everywhere else.
let feedIndex = -1

function feedPosts() {
  return Array.from(document.querySelectorAll("#feed-posts > div[id]"))
}

function moveFeed(delta) {
  const posts = feedPosts()
  if (posts.length === 0) return false
  feedIndex = Math.max(0, Math.min(posts.length - 1, feedIndex + delta))
  // A brand ring hugging the current post. Inline so the feature stays
  // self-contained (the CSP allows inline styles); cleared from the others.
  posts.forEach((p, i) => {
    const on = i === feedIndex
    p.style.boxShadow = on ? "0 0 0 2px var(--color-brand-500, #2563eb)" : ""
    p.style.borderRadius = on ? "1rem" : ""
  })
  posts[feedIndex].scrollIntoView({ behavior: "smooth", block: "center" })
  return true
}

function overlay() {
  return document.getElementById("shortcuts-overlay")
}

// A modal is open: a native <dialog> (this help, the profile editor's "Remove
// date of birth", …) or the welcome questions, which mark themselves
// [data-block-shortcuts]. Every shortcut must stay inert behind it — otherwise
// "n"/"g …" would act on the page under the dialog.
function blockingModalOpen() {
  return !!document.querySelector("dialog[open], [data-block-shortcuts]")
}

// The help is a native <dialog> (VutuvWeb.UI.modal_dialog/1): `showModal()`
// traps the focus, answers Escape and hands the focus back on close, and the
// delegated helper in app.js closes it from its ✕ and its backdrop.
function openOverlay() {
  // Close any open dropdown first so the menu doesn't sit under the modal.
  closeCardMenus()
  const o = overlay()
  if (o && !o.open) o.showModal()
}

let gPending = false
let gTimer = null

function resetSequence() {
  gPending = false
  if (gTimer) clearTimeout(gTimer)
}

function handleKey(e) {
  if (fromForeignShadowRoot(e)) return

  // Escape belongs to whatever dialog is open; here it only ends a pending
  // "g …" sequence. Everything else below is desktop-only.
  if (e.key === "Escape") {
    resetSequence()
    return
  }

  // "?" closes the help it opened, the one key it answers besides Escape.
  if (e.key === "?" && overlay()?.open) {
    e.preventDefault()
    overlay().close()
    return
  }

  // A dialog is open, and every other key must not reach the shortcuts below.
  if (blockingModalOpen()) return

  if (!DESKTOP.matches) return
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (isTyping(e.target)) return

  if (e.key === "?") {
    e.preventDefault()
    openOverlay()
    return
  }

  // Second key of a "g …" navigation sequence.
  if (gPending) {
    resetSequence()
    const dest = {
      h: "/",
      f: loggedIn() && "/feed",
      m: loggedIn() && "/messages",
      n: loggedIn() && "/notifications",
      p: loggedIn() && profilePath(),
    }[e.key]
    if (dest) {
      e.preventDefault()
      go(dest)
    }
    return
  }

  if (e.key === "g") {
    gPending = true
    gTimer = setTimeout(resetSequence, SEQUENCE_WINDOW_MS)
    return
  }

  if (e.key === "/") {
    e.preventDefault()
    go("/search")
    return
  }

  if (e.key === "n" && loggedIn()) {
    e.preventDefault()
    if (!focusComposer()) go("/feed#compose")
    return
  }

  if (e.key === "j" || e.key === "k") {
    if (moveFeed(e.key === "j" ? 1 : -1)) e.preventDefault()
    return
  }
}

document.addEventListener("keydown", handleKey)

// Focus the composer when arriving at /feed#compose (the "n" shortcut fired
// from another page). Runs on DOM ready and after every live navigation.
onReady(focusComposerFromHash)

// The account-menu "Keyboard shortcuts" item. Delegated so it keeps working
// for markup the LiveView shell re-renders.
document.addEventListener("click", (e) => {
  if (!e.target.closest("[data-shortcuts-trigger]")) return
  e.preventDefault()
  openOverlay()
})
