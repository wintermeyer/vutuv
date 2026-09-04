// Pull the feed down to show the waiting posts: the phone's press on the
// "New (n):" pill, made with the thumb that is already on the screen.
//
// The gesture exists only while the pill does. At the top of the page, with
// posts waiting, a downward drag moves the timeline with the finger and an
// arrow fades in over the gap; past the threshold the arrow turns over, and
// letting go then presses the pill (`[data-show-new]` — the first copy found,
// the hidden desktop one, which is fine: both copies fire the same commands and
// neither depends on being visible). The timeline rests a little lower with the
// arrow spinning until the server has taken the pill away (the queue is empty),
// then eases back up.
//
// Touch events, and not the browser's own pull-to-refresh: the installed web
// app has none, and Safari's reloads the whole page, a heavier answer than
// the pill's. While the pull is ours the `touchmove` is cancelled, which is
// what keeps the page from rubber-banding — and Safari from reloading — under
// the drawn pull.
//
// That cancelling listener has to stand BEFORE the finger lands. WebKit works
// out at `touchstart` whether a touch sequence may hold up the main thread,
// and a listener handed over inside that handler is not part of the answer
// (WebKit bug 184250, and 185656 for the moves that stay uncancellable after
// its fix), so on an iPhone every move of the gesture arrived with
// `cancelable: false`, the hook gave the touch back on the first one, and the
// page just rubber-banded: nothing drawn, nothing revealed. Chrome runs the
// same code correctly, which is what kept it hidden here.
//
// A cancellable listener makes the browser wait for us on every move, so it is
// not left standing either: it follows the pill, the one condition that comes
// from outside, and a pull with no pill waiting does nothing anyway. The
// ordinary scroll of a timeline with nothing waiting therefore never sees it.
// The call is made on the FIRST move: a drag that starts upward is left to the
// browser untouched, and once a browser has begun a scroll it ignores a later
// cancel, so there is no deciding a few pixels in.
//
// What it draws has to survive a LiveView patch, and the patch that takes the
// pill away lands exactly during the hold. An inline style on the timeline
// would not (#1143: morphdom drops attributes the server did not render), and
// a custom property on <html> would, but changing an inherited property on the
// root invalidates style for the whole document on every frame of the drag.
// So the slide is a Web Animation on `#feed-body`: a paused animation scrubbed
// by `currentTime` while the finger has it, an eased one for the hold and the
// way back — nothing on the element for a patch to drop, and compositor-only.
// The arrow's opacity and position go inline on its own `phx-update="ignore"`
// element, and the phase onto <html> as `data-feed-pull`, for the stylesheet's
// arrow states.

const RESISTANCE = 0.6
// Drawn pull that arms the release: about 90px of finger, near the native
// gesture's.
const THRESHOLD = 56
const MAX_PULL = 96
// Where the timeline rests while the reveal runs.
const HOLD = 48
const EASE_MS = 220
// A reveal the server never answers (a socket in trouble) must not leave the
// timeline hanging 48px down for good.
const BUSY_CAP_MS = 4000

const MARKER = "data-feed-pull"

function pill() {
  return document.querySelector("[data-show-new]")
}

const slide = (px) => ({ transform: `translateY(${px}px)` })

export const PullToReveal = {
  mounted() {
    this.root = document.documentElement
    this.body = document.getElementById("feed-body")
    this.startY = null
    this.pull = 0

    this.onStart = (event) => {
      if (this.phase() || event.touches.length !== 1) return
      if (window.scrollY > 0 || !pill() || document.getElementById("band-sheet")) return
      this.startY = event.touches[0].clientY
    }

    this.onMove = (event) => {
      if (this.startY === null) return
      const dy = event.touches[0].clientY - this.startY

      if (!this.phase()) {
        if (dy <= 0 || window.scrollY > 0 || !event.cancelable) return this.drop()
        this.setPhase("pulling")
        // 1px of pull per ms, scrubbed by hand below.
        this.scrub = this.body.animate([slide(0), slide(MAX_PULL)], {
          duration: MAX_PULL,
          fill: "both",
        })
        this.scrub.pause()
      }

      event.preventDefault()
      this.draw(Math.min(MAX_PULL, dy * RESISTANCE))
    }

    this.onEnd = () => {
      if (this.startY === null) return
      const pulling = !!this.phase()
      this.drop()
      if (!pulling) return
      if (this.pull >= THRESHOLD) this.release()
      else this.settle()
    }

    document.addEventListener("touchstart", this.onStart, { passive: true })
    document.addEventListener("touchend", this.onEnd)
    document.addEventListener("touchcancel", this.onEnd)

    // The pill arrives and leaves by patch, and both are this hook's business:
    // its arrival is what arms the gesture, and its leaving is the "the reveal
    // is through" that the hold waits for. One observer answers both, over the
    // timeline, which is where both copies of the pill are rendered.
    this.watch = new MutationObserver(() => this.sync())
    this.watch.observe(this.body, { childList: true, subtree: true })
    this.sync()
  },

  // Everything that follows the pill's presence, in one place. Registering the
  // same listener twice is a no-op and so is removing one that is not there, so
  // this needs no memory of what it did last time.
  sync() {
    const waiting = !!pill()

    if (waiting) document.addEventListener("touchmove", this.onMove, { passive: false })
    else document.removeEventListener("touchmove", this.onMove)

    if (!waiting && this.phase() === "busy") this.settle()
  },

  phase() {
    return this.root.getAttribute(MARKER)
  },

  setPhase(phase) {
    this.root.setAttribute(MARKER, phase)
  },

  // The finger is gone, or the drag was never ours: the touch goes back to the
  // browser. The listener stays — taking it off mid-gesture would cost the
  // next one its cancellable first move (see the note at the top).
  drop() {
    this.startY = null
  },

  draw(pull) {
    this.pull = pull
    this.scrub.currentTime = pull
    this.el.style.opacity = Math.min(1, pull / THRESHOLD).toFixed(2)
    // Centred in the gap the pull opens under `#feed`'s 24px top padding: half
    // of both, less half the 36px disc.
    this.el.style.transform = `translateY(${pull / 2 - 6}px)`
    this.setPhase(pull >= THRESHOLD ? "ready" : "pulling")
  },

  // Replace the scrubbed slide with an eased one from where the timeline is.
  ease(to) {
    this.scrub?.cancel()
    this.scrub = this.body.animate([slide(this.pull), slide(to)], {
      duration: EASE_MS,
      easing: "ease-out",
      fill: "both",
    })
    this.pull = to
  },

  release() {
    this.setPhase("busy")
    this.ease(HOLD)
    pill()?.click()
    // The patch that takes the pill away is the "done" signal (`sync`), and
    // this is the cap for a server that never answers.
    this.cap = setTimeout(() => this.settle(), BUSY_CAP_MS)
  },

  clearCap() {
    clearTimeout(this.cap)
    this.cap = null
  },

  settle() {
    this.clearCap()
    this.setPhase("settling")
    this.ease(0)
    this.el.style.opacity = "0"
    this.scrub.onfinish = () => this.clear()
  },

  clear() {
    this.root.removeAttribute(MARKER)
    this.scrub?.cancel()
    this.scrub = null
    this.el.style.opacity = ""
    this.el.style.transform = ""
    this.pull = 0
  },

  destroyed() {
    this.drop()
    this.clearCap()
    this.watch?.disconnect()
    this.watch = null
    document.removeEventListener("touchstart", this.onStart)
    document.removeEventListener("touchmove", this.onMove)
    document.removeEventListener("touchend", this.onEnd)
    document.removeEventListener("touchcancel", this.onEnd)
    this.clear()
  },
}
