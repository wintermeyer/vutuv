// What the editor's two suggestion lists share (issue #1891).
//
// Two of them pop up while you write: the accounts offered after an `@`
// (mention_picker.js) and the blocks offered after a `/` (the slash menu in
// markdown_editor.js). They differ in everything that is theirs — where the
// rows come from, where the panel hangs, what a pick does — and agreed on
// nothing that is shared, so each grew its own copy of "which row is
// highlighted", its own wrap arithmetic and its own key handling. The slash
// menu, written second, shipped without the `aria-activedescendant` half and
// with three defects the older one had already fixed.
//
// So: the *behaviour* lives here, the *rows* stay with whoever renders them.
// Neither list owns a panel, a fetch or a placement in this file.

// One class for both lists, so the stylesheet describes an active row once.
export const ACTIVE_CLASS = "is-active"

// Step an index with wrap at both ends — a short list is faster to reach
// backwards than to walk down to.
export const stepIndex = (index, delta, count) =>
  count === 0 ? 0 : (index + delta + count) % count

// Mark one row as the active one and tell the ANCHOR which it is.
//
// The anchor is the element that actually holds focus — the contenteditable,
// or an input — because in both lists the caret never leaves the text being
// written. `aria-activedescendant` is the whole of how a screen reader follows
// a listbox its user is not focused on, which is why every row needs an `id`
// and why an empty list must clear the attribute rather than point at a row
// that is no longer there.
export const markActiveRow = (rows, index, anchorEl) => {
  rows.forEach((row, i) => {
    const active = i === index
    row.setAttribute("aria-selected", String(active))
    row.classList.toggle(ACTIVE_CLASS, active)
    if (active) row.scrollIntoView({ block: "nearest" })
  })

  if (!anchorEl) return
  const active = rows[index]
  if (active && active.id) anchorEl.setAttribute("aria-activedescendant", active.id)
  else anchorEl.removeAttribute("aria-activedescendant")
}

// A panel pinned to a caret is wrong the moment the page moves under it, and
// nothing tells it so: the editor only re-asks on a ProseMirror transaction,
// and scrolling dispatches none (issue #1898). The prose is its own scroll
// container once it passes ~24rem, so this is not only about the window.
//
// The TRIGGER is shared; the arithmetic is not, and deliberately stays with
// each caller — the mention picker places a <body>-level panel against the
// viewport, the slash menu places a frame-relative one, and folding those into
// one function would be a coincidence dressed as an abstraction.
//
// `capture: true` is what makes one window listener enough: a scroll event on
// an element does NOT bubble, but it does travel down the capture phase, so
// this sees the prose box scrolling as well as the page. The mention picker
// proved that arrangement before there was anywhere to share it from.
//
// Returns the detach function. A caller that dies while the page lives — the
// messages page tears an editor down per closed conversation — must hold it
// and call it, or it leaks a handler on `window` per editor.
export const followsCaret = (onMove) => {
  const handler = () => onMove()

  window.addEventListener("scroll", handler, { passive: true, capture: true })
  window.addEventListener("resize", handler)

  return () => {
    window.removeEventListener("scroll", handler, { capture: true })
    window.removeEventListener("resize", handler)
  }
}

// The keys an open suggestion list owns, in one place so both lists answer
// them the same way. Returns whether the event was taken — the caller swallows
// it only then, so ordinary typing never stops while a list is up.
//
// A MODIFIED key is never a list key. Cmd/Ctrl+Enter submits the composer
// (issue #1196) from a listener on the same element, and a list that ate it
// would turn a post into a heading — which is exactly what the slash menu did
// before this was written down in one place.
export const suggestKey = (event, { move, accept, dismiss }) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return false

  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    move(event.key === "ArrowDown" ? 1 : -1)
    return true
  }

  if (event.key === "Enter" || event.key === "Tab") return accept()

  if (event.key === "Escape") {
    dismiss()
    return true
  }

  return false
}
