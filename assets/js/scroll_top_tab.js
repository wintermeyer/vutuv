// The phone tab bar's Feed tab, doubling as a back-to-top control.
//
// On /feed that tab points at the page under the reader's thumb, so a press is
// a full reload of what they are looking at. Once they have scrolled a screen
// down the useful press is the other one: back to the top, the standing
// convention on phone tab bars. It has to LOOK different before it behaves
// differently, or the press still reads as a reload — so one attribute drives
// both halves and they cannot disagree: `data-page-scrolled` on <html> is what
// swaps the glyph for an arrow (components.css) and what this press handler
// answers to. No arrow, no interception.
//
// Two decisions worth keeping. The state lives on <html>, not on the tab: the
// tab bar is rendered by ShellLive, and morphdom drops any attribute the server
// did not render on the next patch — an unread badge ticking is enough — which
// is what the nav press paint in app.js has to work around. <html> belongs to
// the root layout and no patch walks it. And which tab may do this is the
// server's call, not a path check here: it renders `data-scroll-top` on the
// active tab alone, so this file never has to know what counts as "the feed".

import { reducedMotion } from "./util"

const MARKER = "data-page-scrolled"

// Half a screen down: the first post has gone past, so "back to the top" is
// worth something, and the composer at the top of the feed — the reason the
// reload is worth keeping — is out of sight. Measured against the viewport
// rather than a fixed number of pixels, so a small phone and a tablet cross it
// at the same point in what the reader can actually see.
function scrolledAway() {
  return window.scrollY > window.innerHeight / 2
}

let queued = false

function sync() {
  queued = false
  document.documentElement.toggleAttribute(MARKER, scrolledAway())
}

// Scroll fires per frame on a phone; coalesce to one read per paint.
function onScroll() {
  if (queued) return
  queued = true
  window.requestAnimationFrame(sync)
}

window.addEventListener("scroll", onScroll, { passive: true })
// The threshold is a viewport height, so a rotation moves it.
window.addEventListener("resize", onScroll, { passive: true })

// A reload lands where it left off, and a bfcache restore does not re-run this
// file at all — so answer both rather than assuming a page starts at the top.
sync()
window.addEventListener("pageshow", sync)

document.addEventListener("click", (event) => {
  // Leave a modified click alone: it opens the feed in a new tab, where the
  // reader really is asking for the page and not for this document's scroll.
  if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey) return

  const tab = event.target.closest?.("a[data-scroll-top]")
  if (!tab || !document.documentElement.hasAttribute(MARKER)) return

  event.preventDefault()
  window.scrollTo({ top: 0, behavior: reducedMotion() ? "auto" : "smooth" })
})
