// The emoji picker behind the composer's 🙂 toolbar button (issue #1197).
//
// One panel for the whole page, appended to <body> — the same arrangement the
// lightbox uses, and for the same reason: the post composer and the messages
// page are LiveViews, so a panel rendered inside one would be patched away by an
// unrelated re-render (a counter tick, a typing indicator). Living outside every
// LiveView root, it is the client's alone.
//
// It carries no copy of its own: every word (title, search placeholder, group
// labels, the empty line) comes from the data-emoji-* attributes the server
// rendered on the editor, because the server is the only side that knows the
// reader's language. The emoji NAMES stay the language-neutral shortcode
// (`:tada:`), which doubles as a hint for the type-through.
//
// Mobile is the primary shape, not an afterthought: under 40rem the panel is a
// bottom sheet with 2.75rem (44px) targets, the search field is deliberately NOT
// focused (an on-screen keyboard would swallow the grid it is meant to help you
// scan), and a backdrop makes tapping outside the obvious way out.
import { EMOJI_GROUPS, searchEmoji } from "./emoji_data.js"

// A wide-open query ("a") would otherwise build hundreds of buttons for a
// result set nobody scrolls through.
const MAX_RESULTS = 120

const MOBILE = "(width < 40rem)"

const isMobile = () => window.matchMedia(MOBILE).matches

let panel = null
let session = null

// Parse "smileys:Smileys|people:People|…" (data-emoji-groups) into the tab list,
// keeping the dataset's own group order rather than the attribute's.
const parseGroups = (value) => {
  const labels = new Map(
    (value || "")
      .split("|")
      .filter(Boolean)
      .map((pair) => {
        const at = pair.indexOf(":")
        return [pair.slice(0, at), pair.slice(at + 1)]
      })
  )

  return Object.keys(EMOJI_GROUPS).map((key) => ({
    key,
    label: labels.get(key) || key,
    sample: EMOJI_GROUPS[key][0][0],
  }))
}

const build = () => {
  const el = document.createElement("div")
  el.className = "emoji-picker"
  el.setAttribute("role", "dialog")
  el.hidden = true
  el.tabIndex = -1
  el.innerHTML = `
    <div class="emoji-picker__head">
      <input type="search" class="emoji-picker__search" autocomplete="off"
             autocapitalize="none" spellcheck="false" data-emoji-search>
      <button type="button" class="emoji-picker__close" data-emoji-close>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
             stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>
      </button>
    </div>
    <div class="emoji-picker__tabs" data-emoji-tabs></div>
    <div class="emoji-picker__grid" data-emoji-grid></div>
    <p class="emoji-picker__empty" hidden data-emoji-empty></p>
  `

  const backdrop = document.createElement("div")
  backdrop.className = "emoji-picker__backdrop"
  backdrop.hidden = true

  document.body.append(backdrop, el)

  panel = {
    el,
    backdrop,
    search: el.querySelector("[data-emoji-search]"),
    close: el.querySelector("[data-emoji-close]"),
    tabs: el.querySelector("[data-emoji-tabs]"),
    grid: el.querySelector("[data-emoji-grid]"),
    empty: el.querySelector("[data-emoji-empty]"),
  }

  wire()
  return panel
}

const wire = () => {
  const { el, backdrop, search, grid, tabs } = panel

  // Keep the editor's own selection: a mousedown inside the panel must not blur
  // the prose, or the insert would have no cursor to land at.
  el.addEventListener("mousedown", (event) => {
    if (event.target !== search) event.preventDefault()
  })

  search.addEventListener("input", () => renderGrid())

  // The search field is the keyboard entry point: Enter takes the top match,
  // Down/Right steps into the grid (whose buttons are tabindex=-1, so nothing
  // else would ever reach them), and from there the arrow keys walk it.
  search.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault()
      grid.querySelector("[data-emoji-char]")?.click()
      return
    }

    if (event.key === "ArrowDown" || event.key === "ArrowRight") {
      const first = grid.querySelector("[data-emoji-char]")
      if (!first) return
      event.preventDefault()
      first.focus()
    }
  })

  tabs.addEventListener("click", (event) => {
    const tab = event.target.closest("[data-emoji-group]")
    if (!tab) return
    session.group = tab.dataset.emojiGroup
    // Switching group clears the query: the tabs and the search box are two ways
    // to narrow the same grid, and a leftover query would make a tap on a tab
    // look broken (the group changes, the results do not).
    search.value = ""
    renderTabs()
    renderGrid()
  })

  grid.addEventListener("click", (event) => {
    const button = event.target.closest("[data-emoji-char]")
    if (!button) return
    session.onPick(button.dataset.emojiChar)
    // Picking several in a row is normal (a reaction plus a heart), so the panel
    // stays open on desktop; on a phone it covers the composer, so it closes and
    // gives the writer their text back.
    if (isMobile()) closePicker()
  })

  grid.addEventListener("keydown", (event) => gridKeydown(event))

  el.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.stopPropagation()
      closePicker()
    }
  })

  panel.close.addEventListener("click", () => closePicker())
  backdrop.addEventListener("click", () => closePicker())

  // Clicking anywhere else (including the toolbar button again) closes it.
  document.addEventListener("mousedown", (event) => {
    if (el.hidden) return
    if (el.contains(event.target)) return
    if (session?.anchor?.contains(event.target)) return
    closePicker()
  })

  window.addEventListener("resize", () => place())
  window.addEventListener("scroll", () => place(), { passive: true, capture: true })
}

// Arrow-key navigation across the grid. The column count is read off the
// rendered grid, so it follows the CSS at whatever width the panel is.
const gridKeydown = (event) => {
  const buttons = [...panel.grid.querySelectorAll("[data-emoji-char]")]
  const index = buttons.indexOf(document.activeElement)
  if (index === -1) return

  const columns = Math.max(
    1,
    getComputedStyle(panel.grid).gridTemplateColumns.split(" ").filter(Boolean).length
  )

  const steps = {
    ArrowRight: 1,
    ArrowLeft: -1,
    ArrowDown: columns,
    ArrowUp: -columns,
  }

  const step = steps[event.key]
  if (step === undefined) return

  const next = buttons[index + step]
  event.preventDefault()
  if (next) next.focus()
  else if (step < 0) panel.search.focus()
}

const renderTabs = () => {
  panel.tabs.replaceChildren(
    ...session.groups.map(({ key, label, sample }) => {
      const tab = document.createElement("button")
      tab.type = "button"
      tab.className = "emoji-picker__tab"
      tab.dataset.emojiGroup = key
      tab.title = label
      tab.setAttribute("aria-label", label)
      // A group of toggle buttons, deliberately NOT role="tab": a real tablist
      // owes the reader a roving tabindex and arrow-key navigation of its own,
      // and announcing "tab 3 of 8" while Tab moves normally is worse than
      // announcing what these actually are. aria-pressed is also how the
      // editor's own alignment buttons mark their state.
      tab.setAttribute("aria-pressed", String(key === session.group))
      tab.textContent = sample
      return tab
    })
  )
}

const renderGrid = () => {
  const query = panel.search.value
  const results = searchEmoji(query, session.group).slice(0, MAX_RESULTS)

  panel.grid.replaceChildren(
    ...results.map(({ char, codes }) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "emoji-picker__emoji"
      button.dataset.emojiChar = char
      // The shortcode is both the accessible name and a nudge: see `:tada:`
      // once and you can type it next time.
      button.title = `:${codes[0]}:`
      button.setAttribute("aria-label", `:${codes[0]}:`)
      button.tabIndex = -1
      button.textContent = char
      return button
    })
  )

  const none = results.length === 0
  panel.empty.hidden = !none
  panel.grid.hidden = none
}

// Desktop: a popover pinned under the toolbar button, flipped above when the
// bottom of the window is closer than the panel is tall, and clamped so it never
// hangs off the left or right edge. Mobile: the CSS owns the geometry (a bottom
// sheet), so every inline value is cleared — an inline style would beat it.
const place = () => {
  if (!panel || panel.el.hidden) return
  const { el } = panel

  // The backdrop and the scroll lock belong to the bottom-sheet shape, so they
  // are decided HERE rather than once at open time: rotating a phone crosses
  // 40rem (390 → 844), and a stale backdrop would leave a dark screen behind a
  // small popover.
  const mobile = isMobile()
  panel.backdrop.hidden = !mobile
  document.body.classList.toggle("emoji-picker-open", mobile)

  if (mobile) {
    el.style.top = ""
    el.style.left = ""
    return
  }

  const anchor = session.anchor.getBoundingClientRect()
  const box = el.getBoundingClientRect()
  const margin = 8

  const below = anchor.bottom + margin
  const above = anchor.top - box.height - margin
  const top = below + box.height > window.innerHeight && above > margin ? above : below

  const left = Math.min(
    Math.max(margin, anchor.left),
    Math.max(margin, window.innerWidth - box.width - margin)
  )

  el.style.top = `${Math.max(margin, top)}px`
  el.style.left = `${left}px`
}

export const closePicker = () => {
  if (!panel || panel.el.hidden) return
  panel.el.hidden = true
  panel.backdrop.hidden = true
  document.body.classList.remove("emoji-picker-open")
  const { anchor, onClose } = session || {}
  session = null
  anchor?.focus?.()
  onClose?.()
}

export const pickerOpen = () => Boolean(panel && !panel.el.hidden)

// Close only a picker belonging to `root` (an editor being destroyed). A page can
// hold more than one editor, and tearing one down must not shut the panel the
// other one just opened.
export const closePickerFor = (root) => {
  if (pickerOpen() && root?.contains(session.anchor)) closePicker()
}

/**
 * Open the picker.
 *
 * @param anchor  the toolbar button it hangs off (and where focus returns)
 * @param labels  the editor root's dataset (data-emoji-title / -search / -close
 *                / -empty / -groups) — all copy comes from the server
 * @param onPick  called with the chosen character
 * @param onClose called after the panel closes, for whatever needs the focus back
 */
export const openPicker = ({ anchor, labels, onPick, onClose }) => {
  const p = panel || build()

  session = {
    anchor,
    onPick,
    onClose,
    groups: parseGroups(labels.emojiGroups),
    group: Object.keys(EMOJI_GROUPS)[0],
  }

  p.el.setAttribute("aria-label", labels.emojiTitle || "Emoji")
  p.search.placeholder = labels.emojiSearch || ""
  p.search.setAttribute("aria-label", labels.emojiSearch || "")
  p.search.value = ""
  p.close.title = labels.emojiClose || ""
  p.close.setAttribute("aria-label", labels.emojiClose || "")
  p.empty.textContent = labels.emojiEmpty || ""

  renderTabs()
  renderGrid()

  p.el.hidden = false
  // place() sets the geometry AND the mobile chrome (backdrop, scroll lock).
  place()

  // Desktop: type straight into search, the fastest way to a specific emoji.
  // Mobile: do NOT — the on-screen keyboard would cover the grid the member
  // came to browse. They can still tap the field when they want to search.
  if (isMobile()) p.el.focus()
  else p.search.focus()
}
