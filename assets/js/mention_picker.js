// The composer's `@`-mention picker (issue #1748).
//
// One panel for the whole page, appended to <body>: every editor on this site
// sits inside a LiveView, so a panel rendered in the document would be patched
// away by an unrelated re-render — a typing indicator, an unread badge tick.
// (The emoji picker used to make the same arrangement for the same reason; it
// went with the toolbar button that opened it, issue #1886.)
//
// It is a **listbox the editor drives**, not a thing you tab into: focus never
// leaves the prose, because a mention is typed mid-sentence and taking the
// caret away to choose would cost more than the choosing saves. The editor
// forwards ↑/↓/Enter/Tab/Escape here and marks the active row through
// `aria-activedescendant` on the ProseMirror element, which is how a screen
// reader follows a list its user is not focused on.
//
// It carries no copy of its own: the labels come from the data-mention-*
// attributes the server rendered on the editor, because the server is the only
// side that knows the reader's language.
import { followsCaret, markActiveRow, stepIndex } from "./suggest_list"

const ROW_ID = (index) => `mention-opt-${index}`

let panel = null
let session = null

const build = () => {
  const el = document.createElement("div")
  el.className = "mention-picker"
  el.id = "mention-picker"
  el.hidden = true
  el.innerHTML = `
    <ul class="mention-picker__list" role="listbox" data-mention-list></ul>
    <p class="mention-picker__note" hidden data-mention-empty></p>
    <p class="mention-picker__note mention-picker__note--budget" hidden data-mention-budget></p>
  `

  document.body.append(el)

  panel = {
    el,
    list: el.querySelector("[data-mention-list]"),
    empty: el.querySelector("[data-mention-empty]"),
    budget: el.querySelector("[data-mention-budget]"),
  }

  wire()
  return panel
}

const wire = () => {
  // A mousedown inside the panel must not blur the prose: the pick is applied
  // at the caret, and a blurred editor has no caret to apply it at.
  panel.el.addEventListener("mousedown", (event) => event.preventDefault())

  panel.list.addEventListener("click", (event) => {
    const row = event.target.closest("[data-mention-index]")
    if (!row) return
    pick(Number(row.dataset.mentionIndex))
  })

  // Hovering moves the active row, so the mouse and the arrow keys never
  // disagree about what Enter would take.
  panel.list.addEventListener("mousemove", (event) => {
    const row = event.target.closest("[data-mention-index]")
    if (!row) return
    const index = Number(row.dataset.mentionIndex)
    if (index === session?.active) return
    session.active = index
    markActive()
  })

  // Clicking anywhere else closes the list. Nothing else would: the panel is
  // shut by the editor's own transactions, and leaving the prose dispatches
  // none — ProseMirror's blur handler changes no state — so without this the
  // list outlives the caret it hangs off and sits over the page.
  document.addEventListener("mousedown", (event) => {
    if (!mentionsOpen()) return
    if (panel.el.contains(event.target)) return
    // Inside the editor the caret decides, not the click: moving it dispatches
    // a transaction, and that is what re-asks whether a mention is being typed.
    if (session.anchorEl?.contains(event.target)) return
    closeMentions()
  })

  // The same rule the slash menu follows (issue #1898), from the one place it
  // is written. `wire()` runs once for the page's single panel, so the detach
  // it hands back has nobody to hand it to — that is why this reads as a bare
  // call and the editor's does not.
  followsCaret(() => place())
}

const pick = (index) => {
  const item = session?.items[index]
  if (!item) return
  const { onPick } = session
  closeMentions()
  onPick(item)
}

const markActive = () => {
  markActiveRow([...panel.list.children], session.active, session.anchorEl)
}

const renderRow = (item, index) => {
  const row = document.createElement("li")
  row.className = "mention-picker__row"
  row.id = ROW_ID(index)
  row.setAttribute("role", "option")
  row.setAttribute("aria-selected", "false")
  row.dataset.mentionIndex = String(index)

  const face = document.createElement(item.avatar ? "img" : "span")
  face.className = `mention-picker__face mention-picker__face--${item.kind}`
  if (item.avatar) {
    face.src = item.avatar
    face.alt = ""
    face.loading = "lazy"
  } else {
    // The same initials tile <.avatar> / <.organization_logo> draw for an
    // account with no picture, so the rows read like the rest of the site.
    face.textContent = item.initials || "?"
  }

  const text = document.createElement("span")
  text.className = "mention-picker__text"
  const name = document.createElement("span")
  name.className = "mention-picker__name"
  name.textContent = item.name
  const handle = document.createElement("span")
  handle.className = "mention-picker__handle"
  handle.textContent = `@${item.handle}`
  text.append(name, handle)

  row.append(face, text)
  return row
}

// Pin the panel to the caret: under it when there is room, above it when the
// bottom of the window (or the on-screen keyboard, which `visualViewport`
// reports and `innerHeight` does not) is closer than the panel is tall. Can
// also CLOSE the list — see the out-of-window branch below; all three callers
// (open, resize, scroll) are asking the same question, so it is answered here
// once rather than at each of them.
const place = () => {
  if (!mentionsOpen()) return
  const { el } = panel
  // Asked again on every call, never remembered: this fires on scroll and on
  // resize, and both move the caret under a panel that would otherwise stay
  // where it was opened. Null once the run is gone (the editor is closing the
  // list on the same turn) — leave the panel where it is rather than guess.
  const rect = session.caretRect()
  if (!rect) return
  const box = el.getBoundingClientRect()
  const margin = 8
  const viewport = window.visualViewport
  const height = viewport ? viewport.height : window.innerHeight
  const width = viewport ? viewport.width : window.innerWidth

  // Scrolled the mention out of the window: the list has nothing left to point
  // at, and the clamp below would otherwise park it at the top edge, over
  // whatever the reader scrolled to. Somebody who scrolls away from the word
  // they were typing is done with the list.
  if (rect.bottom < 0 || rect.top > height) return closeMentions()

  const below = rect.bottom + margin
  const above = rect.top - box.height - margin
  const top = below + box.height > height && above > margin ? above : below

  const left = Math.min(
    Math.max(margin, rect.left),
    Math.max(margin, width - box.width - margin)
  )

  el.style.top = `${Math.max(margin, top)}px`
  el.style.left = `${left}px`
}

/**
 * Show the picker: one call per answer, because an empty panel is never a state
 * anybody wants to see. Re-targeting an open one is the same call.
 *
 * @param anchorEl  the contenteditable the caret is in — it carries the list's
 *                  ARIA state, since focus stays there
 * @param labels    the editor root's dataset (data-mention-label / -empty)
 * @param onPick    called with the chosen item
 * @param items     the rows to draw
 * @param caretRect called for the caret box to hang off — a function, not a
 *                  box, because the panel is re-placed on scroll and resize
 * @param budget    optional line under the list ("2 of 5 mentions"), shown only
 *                  where a cap exists — a post has one, a message does not
 */
export const showMentions = ({ anchorEl, labels, onPick, items, caretRect, budget }) => {
  const p = panel || build()

  session = { anchorEl, labels, onPick, items, caretRect, active: 0 }
  p.list.setAttribute("aria-label", labels.mentionLabel || "")
  p.empty.textContent = labels.mentionEmpty || ""

  p.list.replaceChildren(...items.map(renderRow))
  p.list.hidden = items.length === 0
  p.empty.hidden = items.length > 0
  p.budget.hidden = !budget
  p.budget.textContent = budget || ""

  // The prose keeps the caret, so the editable element is what carries the
  // list's ARIA state. `aria-autocomplete="list"` (valid on a textbox, which is
  // what a contenteditable is) is the announcement that suggestions exist;
  // `aria-activedescendant` below is how the active row is read out without the
  // focus ever moving there.
  anchorEl?.setAttribute("aria-autocomplete", "list")
  anchorEl?.setAttribute("aria-controls", "mention-picker")

  p.el.hidden = false
  markActive()
  place()
}

// Rewrite the budget line under an open list. The count it shows depends on an
// answer that arrives after the list was drawn (which handles in the body are
// real), so it has to be able to change without redrawing the rows underneath
// the reader's cursor.
export const setMentionBudget = (budget) => {
  if (!panel || panel.el.hidden) return
  panel.budget.hidden = !budget
  panel.budget.textContent = budget || ""
}

const mentionsOpen = () => Boolean(panel && !panel.el.hidden && session)

// Is the open panel THIS editor's? A page can hold several (the messages page
// holds one per open conversation), and only the one the caret is in may act on
// a keystroke.
export const mentionsOpenFor = (root) => mentionsOpen() && root?.contains(session.anchorEl)

// Move the active row, wrapping at both ends — a five-row list is faster to
// reach backwards than to walk down to.
export const moveMention = (delta) => {
  if (!mentionsOpen() || session.items.length === 0) return
  session.active = stepIndex(session.active, delta, session.items.length)
  markActive()
}

// Take the active row. Answers whether there was one, so the editor knows
// whether to swallow the keystroke.
export const acceptMention = () => {
  if (!mentionsOpen() || session.items.length === 0) return false
  pick(session.active)
  return true
}

export const closeMentions = () => {
  if (!panel || panel.el.hidden) return
  panel.el.hidden = true
  panel.list.replaceChildren()
  const anchorEl = session?.anchorEl
  session = null
  anchorEl?.removeAttribute("aria-activedescendant")
  anchorEl?.removeAttribute("aria-autocomplete")
  anchorEl?.removeAttribute("aria-controls")
}

// Close only a picker belonging to `root` (an editor being destroyed). A page
// can hold more than one editor, and tearing one down must not shut the panel
// the other one just opened.
export const closeMentionsFor = (root) => {
  if (mentionsOpen() && root?.contains(session.anchorEl)) closeMentions()
}
