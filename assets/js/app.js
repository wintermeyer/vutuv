// Include phoenix_html to handle method links such as `method: :delete`
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

// LiveSocket drives the incremental LiveView shell (live unread badges, the
// notifications/messages pages, presence). The CSRF token is rendered into the
// root layout's <meta name="csrf-token">.
const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content")

// Rewrites a <time datetime="…Z"> into the viewer's locale and timezone.
// Server-rendered timestamps are UTC; this runs as the LocalTime hook inside
// LiveViews and as a DOMContentLoaded sweep over time[data-localtime] on
// classic controller pages (post cards render on both kinds of page).
function localizeTime(el) {
  const dt = new Date(el.dateTime)
  if (!isNaN(dt)) {
    el.textContent = new Intl.DateTimeFormat(undefined, {
      dateStyle: "short",
      timeStyle: "short",
    }).format(dt)
  }
}

window.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("time[data-localtime]").forEach(localizeTime)
})

// Hooks. ClearOnSubmit resets a form right after it is submitted (used by the
// message composer so the input empties once a message is sent). LocalTime
// localizes timestamps (see above). ScrollBottom keeps a chat thread pinned
// to its newest message.
const Hooks = {
  ClearOnSubmit: {
    mounted() {
      this.el.addEventListener("submit", () => {
        window.requestAnimationFrame(() => this.el.reset())
      })
    },
  },
  LocalTime: {
    mounted() {
      localizeTime(this.el)
    },
    updated() {
      localizeTime(this.el)
    },
  },
  ScrollBottom: {
    mounted() {
      this.el.scrollTop = this.el.scrollHeight
    },
    updated() {
      this.el.scrollTop = this.el.scrollHeight
    },
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
})

liveSocket.connect()
window.liveSocket = liveSocket

// Flash toasts. Lives outside LiveView so it also works on classic controller
// pages: auto-dismiss info/success after a few seconds, wire the × button, and
// watch the tray so toasts pushed by a LiveView (added to the DOM later) get the
// same treatment. Errors stay until dismissed.
function wireToast(el) {
  if (el.dataset.toastWired) return
  el.dataset.toastWired = "1"

  const closeBtn = el.querySelector("[data-toast-close]")
  if (closeBtn) closeBtn.addEventListener("click", () => el.remove())

  if (el.hasAttribute("data-toast-autodismiss")) {
    // Click the close button instead of removing the node directly: on LiveView
    // pages the button's phx-click="lv:clear-flash" clears the server-side flash
    // too, so a later LiveView patch can't resurrect the dismissed toast.
    setTimeout(() => (closeBtn ? closeBtn.click() : el.remove()), 4500)
  }
}

function setupToasts() {
  const tray = document.getElementById("toast-tray")
  if (!tray) return

  tray.querySelectorAll(".toast").forEach(wireToast)

  if (!tray.dataset.observed) {
    tray.dataset.observed = "1"
    new MutationObserver((mutations) => {
      mutations.forEach((m) =>
        m.addedNodes.forEach((node) => {
          if (node.nodeType === 1 && node.classList.contains("toast")) {
            wireToast(node)
          }
        })
      )
    }).observe(tray, { childList: true })
  }
}

window.addEventListener("DOMContentLoaded", setupToasts)
window.addEventListener("phx:page-loading-stop", setupToasts)

// Username availability. The new-username form (slug/form_content) marks its
// input with data-availability-url; as the user types, ask the server whether
// the handle is valid and free and show the verdict in the #slug-availability
// hint line, so "already taken" appears before the form is submitted. Plain
// JS on a classic controller page (no LiveView there).
function setupSlugAvailability() {
  const input = document.querySelector("input[data-availability-url]")
  const hint = document.getElementById("slug-availability")
  if (!input || !hint) return

  let timer = null

  input.addEventListener("input", () => {
    clearTimeout(timer)
    const value = input.value.trim()

    if (value === "") {
      hint.textContent = ""
      hint.classList.remove("editform__hint--ok", "editform__hint--error")
      return
    }

    timer = setTimeout(async () => {
      try {
        const url = `${input.dataset.availabilityUrl}?value=${encodeURIComponent(value)}`
        // No explicit Accept header: the route lives in the :browser pipeline,
        // whose `accepts ["html"]` 406s an "application/json" Accept; fetch's
        // default */* negotiates fine and the action responds with JSON anyway.
        const resp = await fetch(url)
        if (!resp.ok) return
        const data = await resp.json()
        // A slower response for an older value must not overwrite the verdict
        // for what is in the input now.
        if (input.value.trim() !== value) return
        hint.textContent = data.message
        hint.classList.toggle("editform__hint--ok", data.available)
        hint.classList.toggle("editform__hint--error", !data.available)
      } catch (_e) {
        // Network hiccup: keep quiet, the server still validates on submit.
      }
    }, 300)
  })
}

window.addEventListener("DOMContentLoaded", setupSlugAvailability)

// The ad banner (layout strip between navigation and content, see
// VutuvWeb.Plug.AdBanner) disappears on its own after two minutes: fade out,
// then drop the node. Its ✕ removes it immediately AND keeps ads away for
// the rest of the (Berlin) day: the cookie value is the day stamped onto the
// button by the server, which the plug compares against its own "today".
// Classic controller pages only, so plain JS suffices.
window.addEventListener("DOMContentLoaded", () => {
  const ad = document.querySelector("[data-ad-banner]")
  if (!ad) return

  const close = ad.querySelector("[data-ad-close]")
  if (close) {
    close.addEventListener("click", () => {
      document.cookie = `vutuv_ad_dismissed=${close.dataset.adDay}; path=/; max-age=86400; samesite=lax`
      ad.remove()
    })
  }

  setTimeout(() => {
    ad.style.transition = "opacity 0.5s ease"
    ad.style.opacity = "0"
    setTimeout(() => ad.remove(), 500)
  }, 120000)
})

// Card ⋯ menus (<details data-menu>, see VutuvWeb.UI.card_menu): the native
// <details> toggle does everything except light-dismiss, so close any open
// menu when clicking outside it or pressing Escape. Event delegation keeps
// this working for menus added to the DOM later.
document.addEventListener("click", (e) => {
  document.querySelectorAll("details[data-menu][open]").forEach((menu) => {
    if (!menu.contains(e.target)) menu.removeAttribute("open")
  })
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  document
    .querySelectorAll("details[data-menu][open]")
    .forEach((menu) => menu.removeAttribute("open"))
})

// Avatar fallback. A user's stored avatar file can be missing — a legacy row
// whose image was never imported, a failed upload, a derived version not yet
// regenerated — so the <img> 404s and the browser draws a broken-image icon.
// Swap any avatar that fails to load to the same neutral silhouette a user with
// no avatar already shows, so the lists never show a broken image. Scoped to
// img[data-avatar] (set by VutuvWeb.UI.avatar/1 and user/card_list) so post
// images, link thumbnails and screenshots keep their own fallbacks. Two notes:
// `error` events don't bubble, so we listen in the capture phase; and the swap
// runs once so a fallback that itself fails can't loop.
//
// Keep NEUTRAL_AVATAR identical to `Vutuv.Avatar`'s @default_avatar (the SVG a
// nil-avatar user renders) so a broken avatar is visually indistinguishable.
const NEUTRAL_AVATAR =
  "data:image/svg+xml,%3Csvg%20width%3D%27200%27%20height%3D%27200%27%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20xmlns%3Axlink%3D%27http%3A%2F%2Fwww.w3.org%2F1999%2Fxlink%27%3E%3Cdefs%3E%3Ccircle%20id%3D%27a%27%20cx%3D%27100%27%20cy%3D%27100%27%20r%3D%27100%27%2F%3E%3C%2Fdefs%3E%3Cg%20fill%3D%27none%27%20fill-rule%3D%27evenodd%27%3E%3Cmask%20id%3D%27b%27%20fill%3D%27%23fff%27%3E%3Cuse%20xlink%3Ahref%3D%27%23a%27%2F%3E%3C%2Fmask%3E%3Cuse%20fill%3D%27%23EEE%27%20xlink%3Ahref%3D%27%23a%27%2F%3E%3Cpath%20d%3D%27M88.96%20154c-6.357-12.418-12.81-26.952-19.355-43.597C63.06%2093.76%2056.858%2075.626%2051%2056h29.437c1.247%204.844%202.714%2010.093%204.4%2015.743%201.682%205.653%203.428%2011.365%205.24%2017.143%201.808%205.772%203.615%2011.394%205.425%2016.86%201.81%205.466%203.59%2010.434%205.336%2014.904%201.618-4.47%203.365-9.438%205.234-14.905%201.87-5.465%203.71-11.087%205.518-16.86%201.807-5.777%203.554-11.49%205.237-17.142%201.682-5.65%203.15-10.9%204.395-15.743h28.71c-5.857%2019.626-12.055%2037.76-18.594%2054.403C124.8%20127.048%20118.352%20141.583%20112%20154H88.96z%27%20fill%3D%27%231A1918%27%20opacity%3D%27.1%27%20mask%3D%27url(%23b)%27%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E"

document.addEventListener(
  "error",
  (e) => {
    const img = e.target
    if (
      img.tagName !== "IMG" ||
      !img.hasAttribute("data-avatar") ||
      img.dataset.avatarFallbackApplied
    )
      return
    img.dataset.avatarFallbackApplied = "1"
    img.src = NEUTRAL_AVATAR
  },
  true
)
