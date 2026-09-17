// The daily text ad's card on a profile and in the feed
// (VutuvWeb.AdComponents.ad_card, VutuvWeb.Live.AdSlot). The server decides
// whether a page shows one; this hook runs its countdown.
//
// * The ring around the ✕ empties over two minutes, counting only the time the
//   card is at least half in view in a tab that is in front, and standing still
//   while the pointer or the keyboard focus is on the card. The timer runs only
//   while the card is in view. When the ring is empty the hook sends
//   `ad-expired` and the server takes the card away.
// * The first moment the card is in view it writes the visitor's hour cookie
//   and sends `ad-seen`, which takes a member's hour on the server.
// * The ✕ writes the day cookie on the click itself: the event it also sends
//   removes the card, and this hook with it, in the patch that answers.
//
// A page carries the card twice (rail and phone column, one of them hidden), so
// the countdown and the sighting live per card key (`data-ad-key`, the second it
// was served) for this page load: both copies read one clock, and a card the
// server draws again after it already ran out goes at once. An event lost while
// the socket was down is sent again once it is back.

import { reducedMotion } from "./util"

const DISMISSED_COOKIE = "vutuv_ad_dismissed"
const SEEN_COOKIE = "vutuv_ad_seen"
const LIFETIME_MS = 2 * 60 * 1000
const TICK_MS = 1000

// key => { elapsed, seen }
const cards = new Map()

const cardFor = (key) => {
  if (!cards.has(key)) cards.set(key, { elapsed: 0, seen: false })
  return cards.get(key)
}

const readCookie = (name) =>
  document.cookie
    .split("; ")
    .find((pair) => pair.startsWith(`${name}=`))
    ?.slice(name.length + 1)

const writeCookie = (name, value, maxAge) => {
  document.cookie = `${name}=${value}; path=/; max-age=${maxAge}; samesite=lax`
}

export const AdSlot = {
  mounted() {
    const { adDay: day, adKey: key } = this.el.dataset
    this.card = cardFor(key)

    if (readCookie(DISMISSED_COOKIE) === day) return this.leave("dismiss-ad")
    if (this.expired()) return this.leave("ad-expired")

    this.el.querySelector("[data-ad-dismiss]").addEventListener("click", () => {
      writeCookie(DISMISSED_COOKIE, day, 86400)
    })

    this.arc = this.el.querySelector("[data-ad-ring-arc]")
    this.inView = false
    this.observer = new IntersectionObserver(
      (entries) => {
        this.inView = entries.at(-1).intersectionRatio >= 0.5
        this.sync()
      },
      { threshold: 0.5 },
    )
    this.observer.observe(this.el)
    this.onVisibility = () => this.sync()
    document.addEventListener("visibilitychange", this.onVisibility)
    this.paint()
  },

  reconnected() {
    if (!this.arc) return
    if (this.expired()) this.push("ad-expired")
    this.sync()
  },

  expired() {
    return this.card.elapsed >= LIFETIME_MS
  },

  // Starts or stops the clock to match what the reader can see.
  sync() {
    const running = this.inView && !document.hidden && !this.expired()

    if (running && !this.timer) {
      this.last = performance.now()
      this.timer = setInterval(() => this.tick(), TICK_MS)
    } else if (!running && this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }

    if (running && !this.card.seen) {
      this.card.seen = true
      writeCookie(SEEN_COOKIE, Math.floor(Date.now() / 1000), 3600)
      this.pushEvent("ad-seen", {}).catch(() => {
        this.card.seen = false
      })
    }
  },

  tick() {
    const now = performance.now()
    const step = Math.min(now - this.last, 2 * TICK_MS)
    this.last = now

    if (this.el.matches(":hover, :focus-within")) return

    this.card.elapsed = Math.min(LIFETIME_MS, this.card.elapsed + step)
    this.paint()

    if (this.expired()) {
      this.sync()
      this.push("ad-expired")
    }
  },

  paint() {
    let share = this.card.elapsed / LIFETIME_MS
    if (reducedMotion()) share = Math.floor(share * 10) / 10
    this.arc.style.strokeDashoffset = String(share)
  },

  // A push the socket could not take is repeated by `reconnected()`.
  push(event) {
    this.pushEvent(event, {}).catch(() => {})
  },

  // `hidden` through a JS command, so a patch arriving before the server's
  // answer cannot put the card back.
  leave(event) {
    this.js().setAttribute(this.el, "hidden", "")
    this.push(event)
  },

  destroyed() {
    clearInterval(this.timer)
    this.observer?.disconnect()
    if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
  },
}
