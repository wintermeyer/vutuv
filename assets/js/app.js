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

// Hooks. ClearOnSubmit resets a form right after it is submitted (used by the
// message composer so the input empties once a message is sent). LocalTime
// rewrites a <time datetime="…"> into the viewer's locale and timezone.
// ScrollBottom keeps a chat thread pinned to its newest message.
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
      this.localize()
    },
    updated() {
      this.localize()
    },
    localize() {
      const dt = new Date(this.el.dateTime)
      if (!isNaN(dt)) {
        this.el.textContent = new Intl.DateTimeFormat(undefined, {
          dateStyle: "short",
          timeStyle: "short",
        }).format(dt)
      }
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
