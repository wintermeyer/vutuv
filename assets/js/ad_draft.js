// What somebody has written into the ad booking wizard, kept where a reload
// cannot reach it. Why it is kept here and not in a row on the server, and
// what the server re-checks when it comes back, is in
// `docs/architecture/ads.md`; this file is the two mechanics.
//
// **The gesture.** On a phone the commonest way to reload a page is not the
// reload button, it is a stray pull at the top of it — so while the wizard is
// open <html> carries `data-no-pull-refresh` and the stylesheet does the rest.
// There is nothing on this page a refresh could fetch and everything it could
// destroy.
//
// **The mirror.** The wizard's state is rendered into `data-draft` and copied
// into sessionStorage, for the reloads that happen anyway: the browser's own
// button, a crash, a tab the phone discarded, a socket that came back to a
// fresh server-side mount.
import { sessionGet, sessionSet } from "./util"

const KEY = "vutuv:ad-draft"

export const AdDraft = {
  mounted() {
    document.documentElement.setAttribute("data-no-pull-refresh", "")
    this.handleEvent("ad-draft:clear", () => sessionSet(KEY, null))
    this.restore()
  },

  // Every patch of the wizard lands here, which on a debounced keystroke is
  // some six a second — so the unchanged ones are answered with a string
  // compare rather than with a `setItem`, which the browser persists for tab
  // restore and is therefore not a free poke at memory.
  //
  // An empty attribute is the wizard saying "nothing written yet", which is
  // also what a fresh mount renders after a reconnect — so it is never allowed
  // to be the thing that erases a saved draft. Only the clear event and a
  // deliberate departure do that.
  updated() {
    const draft = this.el.dataset.draft
    if (!draft || draft === this.kept) return

    this.kept = draft
    sessionSet(KEY, draft)
  },

  // A reconnect re-runs `mount/3`: the socket comes back to an empty wizard
  // and patches it over the page the member is looking at. Same errand as a
  // reload, so the same answer. The patch above has already run by now and
  // left the stored draft alone, which is what makes this work.
  reconnected() {
    this.restore()
  },

  restore() {
    const draft = sessionGet(KEY)
    if (!draft) return

    try {
      this.pushEvent("restore-draft", JSON.parse(draft))
    } catch (_e) {
      // Nothing this page wrote, or a half-written value from a browser that
      // ran out of room: it can only be in the way from here on.
      sessionSet(KEY, null)
    }
  },

  // The draft ends when the wizard is taken off a page that goes on living:
  // the booking went through and navigated to the bookings list, or a live
  // patch replaced this view. A document that is on its way out keeps it, and
  // that distinction is the whole point — LiveView destroys its views for an
  // ordinary link click and for any form that posts (the onboarding dialog's
  // "close" is one, and it lands back on this very page), so a blanket clear
  // here threw the ad away for things that were not leaving at all. `unloaded`
  // is set before the views are torn down, which is what makes it readable
  // from in here.
  destroyed() {
    document.documentElement.removeAttribute("data-no-pull-refresh")
    if (!window.liveSocket?.isUnloaded()) sessionSet(KEY, null)
  },
}
