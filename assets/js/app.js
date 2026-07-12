// Include phoenix_html to handle method links such as `method: :delete`
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
// Desktop-only keyboard shortcuts + the "?" help overlay (self-contained,
// gated off touch devices; see keyboard_shortcuts.js).
import "./keyboard_shortcuts"
// Passkey (WebAuthn/FIDO2) login + enrolment ceremony on /login and /settings
// (self-contained, reveals itself only on supporting browsers; see webauthn.js).
import "./webauthn"
// Avatar/cover crop modal on the profile editor (self-contained progressive
// enhancement of the two file inputs; see image_crop.js).
import "./image_crop"
// Shared plumbing (CSRF token, page lifecycle, "wire once" guard, CSRF fetch,
// reduced-motion) reused by every classic-page enhancement below.
import { csrfToken, onReady, once, request, reducedMotion } from "./util"
// The Milkdown WYSIWYG Markdown editor shared by the post + message composers
// (VutuvWeb.UI.markdown_editor/1); registered as the MarkdownEditor hook below.
import { MarkdownEditor } from "./markdown_editor"

// LiveSocket drives the incremental LiveView shell (live unread badges, the
// notifications/messages pages, presence). The CSRF token is rendered into the
// root layout's <meta name="csrf-token"> and read via csrfToken() from ./util.

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

onReady(() =>
  document.querySelectorAll("time[data-localtime]").forEach(localizeTime)
)

// Feed/profile post previews ship the whole body and clamp it to a few lines
// via CSS. Reveal the "Read more" affordance only when the body is really cut —
// i.e. the clamped body overflows, which the server can't know since wrapping is
// width- and font-dependent. A clamped element hides content exactly when its
// full content height (scrollHeight) is taller than its painted box
// (clientHeight); the +1 absorbs sub-pixel rounding.
//
// Both the fade and the control are shown/hidden purely by this `is-clamped`
// class on the WRAPPER (see .post-preview__more / .post-preview__fade in
// components.css) — the control carries no competing `hidden`/`inline-block`
// display utilities, so the cascade conflict that made "Read more" appear on
// every post (issue #880) is structurally gone. Once the reader has expanded a
// preview (`is-expanded`) we leave it alone: a later resize/font sweep must not
// re-clamp it out from under them.
function revealPreviewClamp(el) {
  if (el.classList.contains("is-expanded")) return
  const body = el.querySelector("[data-clamp-body]")
  if (!body) return
  const clipped = body.scrollHeight > body.clientHeight + 1
  el.classList.toggle("is-clamped", clipped)
}

// Expand / collapse a clamped preview in place (the whole body is always in the
// DOM). We animate the body's height between its clamped and full heights: measure both
// around the class flip (getBoundingClientRect forces a sync reflow), then
// transition from start to end and clear the inline overrides once it settles.
// prefers-reduced-motion skips the animation and just flips the state.
function togglePreviewExpand(preview, btn) {
  const body = preview.querySelector("[data-clamp-body]")
  if (!body) return

  const expanding = !preview.classList.contains("is-expanded")

  // Retarget the button's label + aria to the state we're moving to.
  btn.setAttribute("aria-expanded", expanding ? "true" : "false")
  const more = btn.dataset.labelMore
  const less = btn.dataset.labelLess
  if (more && less) btn.textContent = expanding ? less : more

  const flip = () => {
    preview.classList.toggle("is-expanded", expanding)
    preview.classList.toggle("is-clamped", !expanding)
  }

  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    flip()
    return
  }

  const startHeight = body.getBoundingClientRect().height
  flip()
  const endHeight = body.getBoundingClientRect().height

  // Nothing to animate (heights equal) — leave the resting state as flip() set it.
  if (Math.abs(endHeight - startHeight) < 1) return

  body.style.overflow = "hidden"
  body.style.height = `${startHeight}px`
  void body.offsetHeight // force a reflow so the start height paints first
  body.style.transition = "height 250ms ease"
  body.style.height = `${endHeight}px`

  const cleanup = () => {
    body.style.transition = ""
    body.style.height = ""
    body.style.overflow = ""
    body.removeEventListener("transitionend", cleanup)
  }
  body.addEventListener("transitionend", cleanup)
  // Backstop in case transitionend never fires (e.g. the tab was hidden).
  setTimeout(cleanup, 400)
}

// One delegated listener drives every expand button — live or dead page, and it
// survives LiveView stream re-renders (the button is never re-bound).
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-post-expand]")
  if (!btn) return
  e.preventDefault()
  const preview = btn.closest("[data-post-preview]")
  if (preview) togglePreviewExpand(preview, btn)
})

// Sweep every preview on the page (classic pages, and the initial static render
// of live pages). The PostPreviewClamp hook re-checks each one on stream patches;
// a debounced resize sweep catches reflows that change how many lines wrap.
function sweepPreviewClamps() {
  document.querySelectorAll("[data-post-preview]").forEach(revealPreviewClamp)
}

onReady(sweepPreviewClamps)

// A late web-font swap (FOUT) reflows the text and changes how many lines wrap,
// so re-measure once fonts are ready: a card first measured with the wider
// fallback font can otherwise keep a "Read more" link the final font makes
// needless. Cards that stream in later mount post-font, so their hook handles it.
if (document.fonts && document.fonts.ready) {
  document.fonts.ready.then(sweepPreviewClamps)
}

let previewClampResizeTimer
window.addEventListener("resize", () => {
  clearTimeout(previewClampResizeTimer)
  previewClampResizeTimer = setTimeout(sweepPreviewClamps, 150)
})

// Hooks. MarkdownEditor is the Milkdown WYSIWYG composer (posts + messages).
// LocalTime localizes timestamps (see above). ScrollBottom keeps a chat thread
// pinned to its newest message.
const Hooks = {
  MarkdownEditor,
  LocalTime: {
    mounted() {
      localizeTime(this.el)
    },
    updated() {
      localizeTime(this.el)
    },
  },
  // Post-preview clamp (see revealPreviewClamp above): reveal the "Read more"
  // link when the six-line-clamped body overflows. Re-checks on every stream
  // patch so a re-rendered card measures again.
  PostPreviewClamp: {
    mounted() {
      revealPreviewClamp(this.el)
    },
    updated() {
      revealPreviewClamp(this.el)
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
  // Browser-tab title indicator, so a backgrounded tab still shows new activity.
  // ShellLive pushes the state; this hook prefixes document.title:
  //   "(3) vutuv"   unread messages + notifications (exact; shown always)
  //   "•(3) vutuv"  plus new feed posts that arrived while the tab was hidden
  //   "• vutuv"     only new feed posts, nothing unread
  // The feed dot is intentionally gated on document.hidden (feed posts have no
  // read state) and cleared the moment the member returns to the tab. LiveView's
  // <.live_title> rewrites the title on navigation, which would drop our prefix,
  // so a MutationObserver on <title> re-applies it after any external change; the
  // re-apply is idempotent (strip-then-prepend + a no-op guard), so it settles in
  // one extra cycle and never loops.
  TabBadge: {
    mounted() {
      this.unread = 0
      this.feedPending = false

      this.handleEvent("tab:badge", ({ unread }) => {
        this.unread = unread || 0
        this.apply()
      })

      // A new feed post only earns the dot when the member isn't looking here.
      this.handleEvent("tab:new_post", () => {
        if (document.hidden && !this.feedPending) {
          this.feedPending = true
          this.apply()
        }
      })

      // Returning to the tab clears the feed dot.
      this.onVisibility = () => {
        if (!document.hidden && this.feedPending) {
          this.feedPending = false
          this.apply()
        }
      }
      document.addEventListener("visibilitychange", this.onVisibility)

      const titleEl = document.querySelector("title")
      if (titleEl) {
        this.observer = new MutationObserver(() => this.apply())
        this.observer.observe(titleEl, {
          childList: true,
          characterData: true,
          subtree: true,
        })
      }

      this.apply()
    },
    // The indicator string: "•(3) ", "(3) ", "• " or "" when nothing is new.
    prefix() {
      const dot = this.feedPending ? "•" : ""
      const num = this.unread > 0 ? `(${this.unread})` : ""
      const marker = dot + num
      return marker ? `${marker} ` : ""
    },
    apply() {
      // Strip a prefix we added before, then prepend the current one, so the
      // count/dot can rise, fall or vanish without leaving a stale marker.
      const base = document.title.replace(/^\s*•?\s*(\(\d+\)\s*)?/, "")
      const next = this.prefix() + base
      if (next !== document.title) document.title = next
    },
    destroyed() {
      document.removeEventListener("visibilitychange", this.onVisibility)
      if (this.observer) this.observer.disconnect()
    },
  },
  // The admin member browser (VutuvWeb.Admin.UserLive) pages in place over the
  // socket; without this you stay parked at the pager (bottom) after clicking
  // Next/Prev. Scroll the browser card back to the top whenever its page number
  // changes, so each page starts at the top (scroll-mt clears the sticky nav).
  // Typing in the search box keeps page 1, so it never yanks the view.
  PageScroll: {
    mounted() {
      this._page = this.el.dataset.page
    },
    updated() {
      if (this.el.dataset.page !== this._page) {
        this._page = this.el.dataset.page
        this.el.scrollIntoView({ block: "start" })
      }
    },
  },
  // Online presence dots. ShellLive (on every page) pushes this viewer's online
  // user-id set ("presence:set", already filtered against their blocks); this
  // hook reveals each online member's dot via ONE generated stylesheet keyed on
  // the server-rendered data-presence-user-id. Because the rules match by
  // attribute selector (not a JS-set attribute on each node), they keep working
  // for avatars added or re-rendered later — LiveView stream patches (which
  // strip JS-set attributes via morphdom), navigation, classic pages — with no
  // MutationObserver and no per-node bookkeeping to fall out of sync.
  Presence: {
    mounted() {
      this.style = document.createElement("style")
      document.head.appendChild(this.style)

      this.handleEvent("presence:set", ({ online }) => {
        this.style.textContent = (online || [])
          .map(
            (id) =>
              `[data-presence-user-id="${CSS.escape(String(id))}"] .presence-dot{display:block}`
          )
          .join("")
      })
    },
    destroyed() {
      this.style?.remove()
    },
  },
  // Drag-and-drop ordering for the owner's profile-section reorder tool
  // (VutuvWeb.SectionReorderLive). Listeners are delegated to the <ul> so they
  // survive the server re-renders that follow each change. On drop we push the
  // new id order to the LiveView, which renumbers positions 1..n and re-renders
  // (the rows are keyed by id, so the DOM the drag already moved just settles).
  // Touch devices can't fire native HTML5 drag, so the up/down arrows — plain
  // phx-click events — are the reorder path there; this layers desktop drag on
  // top. No CSRF token to manage: it rides the live socket.
  Reorder: {
    mounted() {
      this.dragging = null
      const list = this.el
      const items = () => [...list.querySelectorAll(".reorder__item")]

      // The row the dragged element should sit before, by vertical midpoint.
      const rowAfter = (y) =>
        items()
          .filter((row) => row !== this.dragging)
          .reduce(
            (closest, row) => {
              const box = row.getBoundingClientRect()
              const offset = y - box.top - box.height / 2
              return offset < 0 && offset > closest.offset
                ? { offset, element: row }
                : closest
            },
            { offset: Number.NEGATIVE_INFINITY, element: null }
          ).element

      list.addEventListener("dragstart", (e) => {
        const row = e.target.closest(".reorder__item")
        if (!row) return
        this.dragging = row
        row.classList.add("is-dragging")
      })

      list.addEventListener("dragend", () => {
        if (!this.dragging) return
        this.dragging.classList.remove("is-dragging")
        this.dragging = null
        this.pushEvent("reorder", { order: items().map((el) => el.dataset.id) })
      })

      list.addEventListener("dragover", (e) => {
        e.preventDefault()
        if (!this.dragging) return
        const after = rowAfter(e.clientY)
        if (after == null) {
          list.appendChild(this.dragging)
        } else if (after !== this.dragging) {
          list.insertBefore(this.dragging, after)
        }
      })
    },
    // Animate the arrow/keyboard reorders with FLIP: snapshot each row's top
    // before the server patch (beforeUpdate), then after it (updated) jump each
    // moved row back to where it was and transition to its new spot, so the
    // swap glides instead of teleporting. A drag ends in the same order the DOM
    // already shows, so its delta is 0 and nothing animates. Honors
    // prefers-reduced-motion.
    beforeUpdate() {
      if (reducedMotion()) return
      this._tops = new Map()
      this.el
        .querySelectorAll(".reorder__item")
        .forEach((el) => this._tops.set(el.dataset.id, el.getBoundingClientRect().top))
    },
    updated() {
      if (!this._tops) return
      const rows = [...this.el.querySelectorAll(".reorder__item")]
      // Invert: place each moved row at its old position with no transition.
      rows.forEach((el) => {
        const prev = this._tops.get(el.dataset.id)
        if (prev == null) return
        const delta = prev - el.getBoundingClientRect().top
        if (!delta) return
        el.style.transition = "none"
        el.style.transform = `translateY(${delta}px)`
      })
      // Play: next frame, release to the natural position.
      requestAnimationFrame(() => {
        rows.forEach((el) => {
          if (!el.style.transform) return
          el.style.transition = "transform 180ms ease"
          el.style.transform = ""
        })
      })
      this._tops = null
    },
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken() },
  hooks: Hooks,
})

liveSocket.connect()
window.liveSocket = liveSocket

// Flash toasts. Lives outside LiveView so it also works on classic controller
// pages: EVERY toast (info and error alike) auto-dismisses after a few seconds,
// the × button closes it early, and a MutationObserver gives the same treatment
// to toasts a LiveView pushes into the tray later. One knob for the whole app.
const TOAST_DISMISS_MS = 3000

function wireToast(el) {
  if (!once(el, "toast")) return

  const closeBtn = el.querySelector("[data-toast-close]")
  if (closeBtn) closeBtn.addEventListener("click", () => el.remove())

  // Click the close button instead of removing the node directly: on LiveView
  // pages the button's phx-click="lv:clear-flash" clears the server-side flash
  // too, so a later LiveView patch can't resurrect the dismissed toast.
  setTimeout(() => (closeBtn ? closeBtn.click() : el.remove()), TOAST_DISMISS_MS)
}

function setupToasts() {
  const tray = document.getElementById("toast-tray")
  if (!tray) return

  tray.querySelectorAll(".toast").forEach(wireToast)

  if (once(tray, "toastObserver")) {
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

onReady(setupToasts)

// Username availability. The new-username form (slug/form_content) marks its
// input with data-availability-url; as the user types, ask the server whether
// the handle is valid and free and show the verdict in the #username-availability
// hint line, so "already taken" appears before the form is submitted. Plain
// JS on a classic controller page (no LiveView there).
function setupSlugAvailability() {
  const input = document.querySelector("input[data-availability-url]")
  const hint = document.getElementById("username-availability")
  if (!input || !hint || !once(input, "slug")) return

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

onReady(setupSlugAvailability)

// Work-experience organization link (issue #931). The work-experience form marks a
// [data-organization-link] box; as the member types the organization, ask the server
// for a matching verified organization page and offer a quiet one-tap link. The
// hidden work_experience[organization_id] carries the choice. No match -> no UI.
// Plain JS on a classic controller page (no LiveView there).
function setupOrganizationLink() {
  document.querySelectorAll("[data-organization-link]").forEach((box) => {
    if (!once(box, "organizationLink")) return
    const form = box.closest("form")
    if (!form) return
    const orgInput = form.querySelector('[name$="[organization]"]')
    const idInput = box.querySelector('[name$="[organization_id]"]')
    const status = box.querySelector("[data-organization-link-status]")
    if (!orgInput || !idInput || !status) return

    const labels = {
      suggest: box.dataset.labelSuggest || "Link to {name}?",
      link: box.dataset.labelLink || "Link to page",
      linked: box.dataset.labelLinked || "Linked to {name}",
      unlink: box.dataset.labelUnlink || "Remove link",
    }

    // Seed the already-linked organization (editing a linked experience), so the
    // linked state renders with the organization name even before the first fetch.
    let linked =
      idInput.value && box.dataset.linkedId === idInput.value
        ? { id: box.dataset.linkedId, name: box.dataset.linkedName || "", path: box.dataset.linkedPath || "" }
        : null
    let suggestion = null
    let timer = null

    // A label template holding a "{name}" placeholder, rendered with the name as
    // a real element (link/strong) so it is never HTML-injected as a string.
    function render(template, nameEl, actionEl) {
      const [before, after] = template.split("{name}")
      const frag = document.createDocumentFragment()
      frag.append(document.createTextNode(before))
      if (nameEl) frag.append(nameEl)
      frag.append(document.createTextNode(after !== undefined ? after : ""))
      if (actionEl) frag.append(document.createTextNode(" "), actionEl)
      status.replaceChildren(frag)
      status.hidden = false
    }

    function button(text, className, onClick) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.textContent = text
      btn.className = className
      btn.addEventListener("click", onClick)
      return btn
    }

    function renderState() {
      if (linked) {
        const nameEl = linked.path
          ? Object.assign(document.createElement("a"), {
              href: linked.path,
              textContent: linked.name,
              target: "_blank",
              rel: "noopener",
              className: "font-semibold",
            })
          : Object.assign(document.createElement("strong"), { textContent: linked.name })
        const unlink = button(labels.unlink, "font-semibold text-slate-600 underline hover:text-slate-800", () => {
          idInput.value = ""
          linked = null
          renderState()
          check()
        })
        render(labels.linked, nameEl, unlink)
      } else if (suggestion && suggestion.id !== idInput.value) {
        const nameEl = Object.assign(document.createElement("strong"), { textContent: suggestion.name })
        const link = button(labels.link, "font-semibold text-brand-600 underline hover:text-brand-700", () => {
          idInput.value = suggestion.id
          linked = suggestion
          suggestion = null
          renderState()
        })
        render(labels.suggest, nameEl, link)
      } else {
        status.hidden = true
        status.replaceChildren()
      }
    }

    async function check() {
      if (linked) return
      const value = orgInput.value.trim()
      if (value.length < 2) {
        suggestion = null
        return renderState()
      }
      try {
        const url = `${box.dataset.suggestUrl}?q=${encodeURIComponent(value)}`
        const resp = await fetch(url)
        if (!resp.ok) return
        const data = await resp.json()
        // Ignore a stale response for an organization value already replaced.
        if (orgInput.value.trim() !== value) return
        suggestion = data.organization
        renderState()
      } catch (_e) {
        // Network hiccup: stay quiet, the free-text organization still works.
      }
    }

    orgInput.addEventListener("input", () => {
      if (linked) return // keep the accepted link; unlink first to change it
      clearTimeout(timer)
      timer = setTimeout(check, 300)
    })

    renderState()
    if (!linked) check()
  })
}

onReady(setupOrganizationLink)

// Make horizontally-scrollable code blocks and tables in rendered Markdown
// keyboard-focusable, so they can be scrolled without a mouse (WCAG 2.1.1).
function markFocusableScrollers() {
  document.querySelectorAll(".markdown pre, .markdown table").forEach((el) => {
    if (el.scrollWidth > el.clientWidth && !el.hasAttribute("tabindex")) {
      el.tabIndex = 0
    }
  })
}
onReady(markFocusableScrollers)

// Tag endorsement pills on the profile (VutuvWeb.UI.tag_vote): each is a CSRF
// <form data-tag-vote> whose single count pill is the toggle button. Enhance it to
// toggle the endorsement over fetch (POST to endorse, DELETE to undo) instead of a
// full page reload, then pop the count when it changes. The form's action/method
// are the no-JS fallback; once wired we always intercept. The server returns the
// fresh {count, endorsed}; flipping data-endorsed restyles the pill via the
// data-[endorsed=true]: utilities. Classic controller page, so plain JS (no
// LiveView here).
function popCount(el) {
  if (reducedMotion()) return
  el.animate(
    [{ transform: "scale(1)" }, { transform: "scale(1.4)" }, { transform: "scale(1)" }],
    { duration: 260, easing: "ease-out" }
  )
}

// Keep the chip's hover roster in step with a toggle: show/hide the viewer's own
// pre-rendered row, then enable hover only while at least one row is visible.
function updateRoster(form, endorsed) {
  const chip = form.closest(".group")
  const popover = chip && chip.querySelector("[data-roster]")
  if (!popover) return

  const selfRow = popover.querySelector("[data-self-endorser]")
  if (selfRow) selfRow.classList.toggle("hidden", !endorsed)

  const hasRows = popover.querySelector("[data-roster-row]:not(.hidden)") !== null
  popover.classList.toggle("group-hover:block", hasRows)
  popover.classList.toggle("group-focus-within:block", hasRows)
}

function wireTagVote(form) {
  if (!once(form, "tagVote")) return

  const button = form.querySelector("button")
  const countEl = form.querySelector("[data-tag-vote-count]")

  form.addEventListener("submit", async (e) => {
    e.preventDefault()
    if (form.dataset.busy) return
    form.dataset.busy = "1"

    const endorsed = button.dataset.endorsed === "true"
    const url = endorsed ? form.dataset.unendorseUrl : form.dataset.endorseUrl
    const method = endorsed ? "DELETE" : "POST"

    try {
      const resp = await request(url, { method })
      if (!resp.ok) throw new Error(`tag vote ${resp.status}`)
      const { count, endorsed: nowEndorsed } = await resp.json()

      button.dataset.endorsed = String(nowEndorsed)
      button.setAttribute("aria-pressed", String(nowEndorsed))
      button.title = nowEndorsed ? form.dataset.labelUnendorse : form.dataset.labelEndorse

      // The pill shows a "+" (invite to endorse) only while nobody has, so a
      // count that drops to 0 reverts to "+" rather than showing a bare "0".
      const display = !nowEndorsed && count === "0" ? "+" : count
      if (countEl.textContent.trim() !== display) {
        countEl.textContent = display
        popCount(countEl)
      }

      // Reflect the change in the hover roster: reveal/hide the viewer's own
      // pre-rendered row, and only enable hover while the popover has a row to show
      // (so a freshly-unendorsed tag with no other endorsers stops popping an empty
      // card on hover).
      updateRoster(form, nowEndorsed)
    } catch (_e) {
      // Network/permission hiccup: leave the pill as it was; a reload re-syncs.
    } finally {
      delete form.dataset.busy
    }
  })
}

function setupTagVotes() {
  document.querySelectorAll("form[data-tag-vote]").forEach(wireTagVote)
}
onReady(setupTagVotes)

// Map links on the profile address card (user/show + Vutuv.Maps). A logged-in
// viewer has a default map service rendered as the primary "Open in …" button,
// the rest as a quiet "Also on" line. Clicking an alternative promotes it: the
// map opens in a new tab, the clicked service becomes the primary button on
// every address row at once, and the new default is persisted (keepalive POST,
// so it survives the tab switch). The links are real <a> tags, so with JS off
// they still open — the default just stays put. Rows without a persist URL
// (logged-out visitors) are left as plain links. Classic controller page, so
// plain JS (no LiveView here).
function mapSnapshot(link) {
  return {
    service: link.dataset.service,
    href: link.getAttribute("href"),
    labelPrimary: link.dataset.labelPrimary,
    labelAlt: link.dataset.labelAlt,
  }
}

function mapApply(link, data, asPrimary) {
  link.dataset.service = data.service
  link.setAttribute("href", data.href)
  link.dataset.labelPrimary = data.labelPrimary
  link.dataset.labelAlt = data.labelAlt
  const text = link.querySelector("[data-map-text]")
  if (text) text.textContent = asPrimary ? data.labelPrimary : data.labelAlt
}

// Across every address row, swap the primary button with the matching
// alternative so `service` reads as the primary everywhere at once.
function promoteMapDefault(service) {
  document.querySelectorAll("[data-map-row]").forEach((row) => {
    const primary = row.querySelector("[data-map-primary]")
    if (!primary || primary.dataset.service === service) return
    const alt = row.querySelector(`[data-map-alt][data-service="${service}"]`)
    if (!alt) return
    const wasPrimary = mapSnapshot(primary)
    const wasAlt = mapSnapshot(alt)
    mapApply(primary, wasAlt, true)
    mapApply(alt, wasPrimary, false)
  })
}

function persistMapDefault(url, service) {
  try {
    request(url, {
      method: "POST",
      keepalive: true,
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `service=${encodeURIComponent(service)}`,
    })
  } catch (_e) {
    // Best effort: a reload re-reads the stored default anyway.
  }
}

function wireMapRow(row) {
  if (!once(row, "map")) return
  const persistUrl = row.dataset.mapPersistUrl
  if (!persistUrl) return // logged-out: plain links, no promotion
  row.querySelectorAll("[data-map-alt]").forEach((alt) => {
    alt.addEventListener("click", (e) => {
      e.preventDefault()
      const service = alt.dataset.service
      window.open(alt.getAttribute("href"), "_blank", "noopener,noreferrer")
      promoteMapDefault(service)
      persistMapDefault(persistUrl, service)
    })
  })
}

function setupMapLinks() {
  document.querySelectorAll("[data-map-row]").forEach(wireMapRow)
}
onReady(setupMapLinks)

// Drag-and-drop for the LinkedIn import ZIP (Step 2 of the import page). The
// <label data-dropzone> wraps a real, sr-only file input, so the form still
// posts multipart exactly as before and the picker/submit work with JS off —
// this only lets the member drop a file onto the zone, highlights it while a
// file is dragged over, and shows the chosen filename. Classic controller page,
// so plain JS suffices.
function wireDropzone(zone) {
  if (!once(zone, "dropzone")) return
  const input = zone.querySelector("[data-dropzone-input]")
  if (!input) return
  const prompt = zone.querySelector("[data-dropzone-prompt]")
  const name = zone.querySelector("[data-dropzone-name]")
  // Optional size guard: the zone carries the byte cap and a localized
  // message, so an oversized pick is flagged (and the submit disabled) before
  // the member waits out a doomed upload. The server still enforces the cap.
  const error = zone.querySelector("[data-dropzone-error]")
  const form = zone.closest("form")
  const submit = form && form.querySelector('button[type="submit"]')
  const maxBytes = parseInt(zone.dataset.maxBytes || "", 10)

  const showChosen = () => {
    const file = input.files && input.files[0]
    if (!file || !name) return
    const tooBig = Boolean(maxBytes) && file.size > maxBytes
    name.textContent = file.name
    name.classList.remove("hidden")
    if (prompt) prompt.classList.add("hidden")
    if (error) {
      error.textContent = tooBig ? zone.dataset.tooLarge || "" : ""
      error.classList.toggle("hidden", !tooBig)
    }
    if (submit) submit.disabled = tooBig
  }

  input.addEventListener("change", showChosen)

  ;["dragenter", "dragover"].forEach((ev) =>
    zone.addEventListener(ev, (e) => {
      e.preventDefault()
      zone.dataset.dragover = "true"
    })
  )
  ;["dragleave", "dragend"].forEach((ev) =>
    zone.addEventListener(ev, (e) => {
      // Ignore dragleave bubbling up from a child element still inside the zone.
      if (ev === "dragleave" && zone.contains(e.relatedTarget)) return
      delete zone.dataset.dragover
    })
  )

  zone.addEventListener("drop", (e) => {
    e.preventDefault()
    delete zone.dataset.dragover
    const dropped = e.dataTransfer && e.dataTransfer.files
    if (!dropped || !dropped.length) return
    // Non-multiple input: keep just the first file, via a fresh DataTransfer.
    const dt = new DataTransfer()
    dt.items.add(dropped[0])
    input.files = dt.files
    showChosen()
  })
}

function setupDropzones() {
  document.querySelectorAll("[data-dropzone]").forEach(wireDropzone)
}
onReady(setupDropzones)

// "Select all / deselect all" toggle for each candidate group on the LinkedIn
// import preview page. Progressive: the button starts hidden and does nothing
// with JS off (the checkboxes are still individually selectable), so this only
// adds a one-click flip over every checkbox inside the enclosing
// [data-select-group]. The button carries both localized labels as data-* so
// no translated text is hardcoded here.
function wireSelectAll(btn) {
  if (!once(btn, "selectAll")) return
  const group = btn.closest("[data-select-group]")
  if (!group) return
  const boxes = () => [...group.querySelectorAll('input[type="checkbox"]')]

  const sync = () => {
    const all = boxes()
    const allChecked = all.length > 0 && all.every((b) => b.checked)
    btn.dataset.state = allChecked ? "all" : "some"
    btn.textContent = allChecked
      ? btn.dataset.labelDeselect
      : btn.dataset.labelSelect
  }

  btn.addEventListener("click", () => {
    const check = btn.dataset.state !== "all"
    boxes().forEach((b) => {
      b.checked = check
    })
    sync()
  })

  // Keep the label honest when the member toggles individual boxes by hand.
  group.addEventListener("change", (e) => {
    if (e.target.matches('input[type="checkbox"]')) sync()
  })

  btn.classList.remove("hidden")
  sync()
}

function setupSelectAll() {
  document.querySelectorAll("[data-select-all]").forEach(wireSelectAll)
}
onReady(setupSelectAll)

// "Type your username to confirm" gate on the account-deletion page
// (<form data-delete-gate>, see settings/delete_account.html.heex). Progressive
// enhancement only: with JS off the red button stays clickable and the server
// re-checks the username (UserController.delete), so this just disables the
// button until the field matches, sparing a needless round-trip. The match is
// normalized the same way the server does it: trim, drop a leading "@",
// lower-case.
function normalizeUsername(value) {
  return value.trim().replace(/^@+/, "").toLowerCase()
}

function wireDeleteGate(form) {
  if (!once(form, "deleteGate")) return
  const input = form.querySelector("[data-delete-gate-input]")
  const submit = form.querySelector("[data-delete-gate-submit]")
  const expected = normalizeUsername(form.dataset.username || "")
  if (!input || !submit || !expected) return

  const sync = () => {
    submit.disabled = normalizeUsername(input.value) !== expected
  }

  input.addEventListener("input", sync)
  sync()
}

function setupDeleteGate() {
  document.querySelectorAll("form[data-delete-gate]").forEach(wireDeleteGate)
}
onReady(setupDeleteGate)

// Copy-to-clipboard button ([data-copy], see settings/security.html.heex's
// permanent profile link). Progressive enhancement: with JS off the target is
// select-all so it can be copied by hand; this just makes it one click. The
// button copies the textContent of the element named by data-copy-target (an
// id) and, for ~1.5s, swaps its label from data-label-copy to data-label-copied
// so no translated text is hardcoded here. writeText needs a secure context
// (https or localhost — every place vutuv runs), so a hidden-textarea +
// execCommand fallback covers older/insecure ones.
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text)
  }
  const area = document.createElement("textarea")
  area.value = text
  area.setAttribute("readonly", "")
  area.style.position = "absolute"
  area.style.left = "-9999px"
  document.body.appendChild(area)
  area.select()
  try {
    document.execCommand("copy")
    return Promise.resolve()
  } catch (err) {
    return Promise.reject(err)
  } finally {
    document.body.removeChild(area)
  }
}

function wireCopyButton(btn) {
  if (!once(btn, "copy")) return
  const target = document.getElementById(btn.dataset.copyTarget)
  const source = () =>
    btn.dataset.copyText || (target ? target.textContent.trim() : "")
  const copied = btn.dataset.labelCopied
  const idle = btn.dataset.labelCopy || btn.textContent
  let revert

  btn.addEventListener("click", () => {
    copyText(source())
      .then(() => {
        if (!copied) return
        btn.textContent = copied
        clearTimeout(revert)
        revert = setTimeout(() => {
          btn.textContent = idle
        }, 1500)
      })
      .catch(() => {})
  })
}

function setupCopyButtons() {
  document.querySelectorAll("[data-copy]").forEach(wireCopyButton)
}
onReady(setupCopyButtons)

// Live character counter for a length-capped text field (the profile Tagline,
// see user/edit.html.heex). A [data-char-counter] wrapper with data-max holds a
// [data-char-count-input] field and a [data-char-count-readout] showing
// "N/max characters"; as the writer types we update the number and flip the
// readout to its over-limit state (red, ⚠ instead of ✓) so they can tell at a
// glance whether they trimmed enough before submitting. Server-side
// validate_length stays the source of truth — this only spares a round-trip.
// Counts code points (not UTF-16 units) so an emoji or astral char reads as one.
function wireCharCounter(wrap) {
  if (!once(wrap, "charCounter")) return
  const input = wrap.querySelector("[data-char-count-input]")
  const readout = wrap.querySelector("[data-char-count-readout]")
  const output = wrap.querySelector("[data-char-count]")
  const ok = wrap.querySelector("[data-char-ok]")
  const over = wrap.querySelector("[data-char-over]")
  const max = parseInt(wrap.dataset.max, 10)
  if (!input || !readout || !output || !max) return

  const update = () => {
    const used = [...input.value].length
    const isOver = used > max
    output.textContent = used
    readout.dataset.over = isOver ? "true" : "false"
    if (ok) ok.classList.toggle("hidden", isOver)
    if (over) over.classList.toggle("hidden", !isOver)
  }

  input.addEventListener("input", update)
  update()
}

function setupCharCounters() {
  document.querySelectorAll("[data-char-counter]").forEach(wireCharCounter)
}
onReady(setupCharCounters)

// Reveal the "Jobsuche" details panel only once an employment status is chosen
// (issue #928, see user/edit.html.heex). A member who leaves the status at "Not
// open to work" should see one clean control; the panel ([data-jobsearch-details]
// -- availability visibility + salary expectation, server-rendered hidden when
// no status is set) appears as soon as they pick "Open to offers" / "Looking for
// a job" and hides again when they clear it. Plain <div> wrappers, so toggling
// `hidden` alone governs display (no competing display utility). With JS off the
// server-side state stands and the panel surfaces after the first save.
function wireEmploymentVisibility(select) {
  if (!once(select, "employmentVisibility")) return
  const wrap = select
    .closest("[data-employment-status-field]")
    ?.querySelector("[data-jobsearch-details]")
  if (!wrap) return

  const sync = () => wrap.classList.toggle("hidden", select.value === "")
  select.addEventListener("change", sync)
  sync()
}

function setupEmploymentVisibility() {
  document
    .querySelectorAll("[data-employment-status-select]")
    .forEach(wireEmploymentVisibility)
}
onReady(setupEmploymentVisibility)

// The profile editor's "Remove date of birth" control (see user/edit.html.heex).
// The native <input type="date"> gives no clear affordance in some browsers
// (Safari on macOS renders spinners with no ✕), so a member could set a birthday
// but never remove it (issue #901). The trigger is a real submit
// (name=clear_birthdate) so it still works with JS off; here we intercept it and
// ask "Are you sure?" in a designed dialog first, then submit for real. We use
// form.requestSubmit(trigger) so the trigger's name/value ride along and the
// controller nils the date even though the date input still carries its old
// value (form.submit() would drop the submitter, and thus clear_birthdate).
function setupBirthdayRemove() {
  const trigger = document.querySelector("[data-birthday-remove]")
  const modal = document.getElementById("birthday-remove-modal")
  if (!trigger || !modal || !once(modal, "birthdayRemove")) return

  const confirmBtn = modal.querySelector("[data-birthday-remove-confirm]")
  let lastFocused = null

  const open = () => {
    lastFocused = document.activeElement
    modal.classList.remove("hidden")
    confirmBtn?.focus()
  }
  const close = () => {
    modal.classList.add("hidden")
    if (lastFocused && typeof lastFocused.focus === "function") lastFocused.focus()
    lastFocused = null
  }

  trigger.addEventListener("click", (e) => {
    e.preventDefault()
    open()
  })

  confirmBtn?.addEventListener("click", () => {
    const form = trigger.form
    close()
    if (form && form.requestSubmit) {
      form.requestSubmit(trigger)
    } else if (form) {
      // Fallback for browsers without requestSubmit: carry clear_birthdate by hand.
      const hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = trigger.name
      hidden.value = trigger.value
      form.appendChild(hidden)
      form.submit()
    }
  })

  // Cancel button and backdrop dismiss without removing anything.
  modal.addEventListener("click", (e) => {
    if (
      e.target.closest("[data-birthday-remove-cancel]") ||
      e.target.hasAttribute("data-birthday-remove-backdrop")
    ) {
      close()
    }
  })

  // Esc closes; Tab cycles between the two buttons so focus can't slip behind
  // the modal. (The keyboard-shortcuts handler also swallows shortcuts while a
  // [data-block-shortcuts] modal is open, so "n"/"g …" don't fire behind it.)
  modal.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      e.preventDefault()
      close()
      return
    }
    if (e.key !== "Tab") return
    const buttons = modal.querySelectorAll("button")
    if (buttons.length === 0) return
    const first = buttons[0]
    const last = buttons[buttons.length - 1]
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  })
}
onReady(setupBirthdayRemove)

// The ad banner (layout strip between navigation and content, see
// VutuvWeb.Plug.AdBanner) disappears on its own after two minutes: fade out,
// then drop the node. Its ✕ removes it immediately AND keeps ads away for
// the rest of the (Berlin) day: the cookie value is the day stamped onto the
// button by the server, which the plug compares against its own "today".
// Classic controller pages only, so plain JS suffices.
onReady(() => {
  const ad = document.querySelector("[data-ad-banner]")
  if (!ad || !once(ad, "adBanner")) return

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
