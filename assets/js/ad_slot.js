// The daily text ad's card on a profile and in the feed
// (VutuvWeb.AdComponents.ad_card, VutuvWeb.Live.AdSlot). The server decides
// whether a page shows one and when it goes; this hook only keeps the day a
// reader closed it.
//
// * The ✕ writes the day into the cookie VutuvWeb.AdServing reads, on the
//   click itself: the event it also sends removes the card, and this hook with
//   it, in the patch that answers.
// * A reconnect mounts the page again with the ad its request chose. A card
//   closed today is sent away again at once, since the socket cannot read the
//   cookie.

const DISMISSED_COOKIE = "vutuv_ad_dismissed"

const readCookie = (name) =>
  document.cookie
    .split("; ")
    .find((pair) => pair.startsWith(`${name}=`))
    ?.slice(name.length + 1)

export const AdSlot = {
  mounted() {
    const day = this.el.dataset.adDay

    if (readCookie(DISMISSED_COOKIE) === day) {
      this.pushEvent("dismiss-ad", {})
      return
    }

    this.el.querySelector("[data-ad-dismiss]")?.addEventListener("click", () => {
      document.cookie = `${DISMISSED_COOKIE}=${day}; path=/; max-age=86400; samesite=lax`
    })
  },
}
