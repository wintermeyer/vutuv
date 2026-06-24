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

import { onReady } from "./util"

const DESKTOP = window.matchMedia("(hover: hover) and (pointer: fine)")

const SEQUENCE_WINDOW_MS = 1500

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

// "n" (new post): focus the feed composer if it is on the page, otherwise jump
// to the feed and focus it on arrival (#compose). Returning false (no composer
// here) is what makes the handler navigate to the feed instead.
function focusComposer() {
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

// On the feed the composer starts collapsed (display:none) behind a "Write a
// post" tile, and focus() is a no-op on a display:none node, so click the
// reveal trigger first, then focus once it paints. The reveal is a LiveView
// round-trip, and on a cross-page arrival (#compose) the socket may still be
// joining, which swallows the first click; so retry the click each tick until
// the panel is actually visible, then focus. Re-clicking once it is open is a
// harmless no-op (the trigger is gone from the DOM by then).
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

function overlayOpen() {
  const o = overlay()
  return o && !o.classList.contains("hidden")
}

// The element focus was on before the dialog opened, so it can be restored
// when the dialog closes (don't strand keyboard focus on a now-hidden node).
let lastFocused = null

function openOverlay() {
  // Close any open dropdown first so the menu doesn't sit under the modal.
  document
    .querySelectorAll("details[data-menu][open]")
    .forEach((m) => m.removeAttribute("open"))
  const o = overlay()
  if (!o) return
  lastFocused = document.activeElement
  o.classList.remove("hidden")
  // Move focus into the dialog so Esc / Tab land there and screen readers
  // announce it.
  o.querySelector("[data-overlay-close]")?.focus()
}

function closeOverlay() {
  const o = overlay()
  if (!o || o.classList.contains("hidden")) return
  o.classList.add("hidden")
  if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus()
  lastFocused = null
}

let gPending = false
let gTimer = null

function resetSequence() {
  gPending = false
  if (gTimer) clearTimeout(gTimer)
}

function handleKey(e) {
  // Escape closes the overlay even on touch / inside fields, so a keyboard user
  // is never trapped. Everything else below is desktop-only.
  if (e.key === "Escape") {
    if (overlayOpen()) closeOverlay()
    resetSequence()
    return
  }

  // While the help dialog is open it is modal: Tab stays trapped on its close
  // button, "?" closes it, and every other shortcut is inert behind it.
  if (overlayOpen()) {
    if (e.key === "Tab") {
      e.preventDefault()
      overlay().querySelector("[data-overlay-close]")?.focus()
    } else if (e.key === "?") {
      e.preventDefault()
      closeOverlay()
    }
    return
  }

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

// The account-menu "Keyboard shortcuts" item, the overlay's close button, and a
// backdrop click. Delegated so it keeps working for markup the LiveView shell
// re-renders.
document.addEventListener("click", (e) => {
  if (e.target.closest("[data-shortcuts-trigger]")) {
    e.preventDefault()
    openOverlay()
    return
  }
  if (
    e.target.closest("[data-overlay-close]") ||
    e.target.hasAttribute("data-overlay-backdrop")
  ) {
    closeOverlay()
  }
})
