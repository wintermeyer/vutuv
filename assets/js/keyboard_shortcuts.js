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
// starts a Gmail-style two-key navigation sequence (g h, g f, …). Navigation
// is a plain location change so it works identically on classic controller
// pages and LiveView pages.

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

  // While the help dialog is open it is modal: keep Tab on its single control
  // (the close button) so keyboard focus can't wander to the page behind it.
  if (overlayOpen() && e.key === "Tab") {
    e.preventDefault()
    overlay().querySelector("[data-overlay-close]")?.focus()
    return
  }

  if (!DESKTOP.matches) return
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (isTyping(e.target)) return

  if (e.key === "?") {
    e.preventDefault()
    overlayOpen() ? closeOverlay() : openOverlay()
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
    go("/feed")
    return
  }
}

document.addEventListener("keydown", handleKey)

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
