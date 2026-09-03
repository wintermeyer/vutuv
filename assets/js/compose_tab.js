// The phone tab bar's Write tab (`data-mobile-compose` in ShellLive).
//
// It is a link to `/feed#compose`, the composer deep link the launcher shortcut
// already uses, so from a page with no composer of its own it is a plain
// navigation and the arrival handler in keyboard_shortcuts.js opens the
// composer. Where the page already has one — the feed, and the owner's own
// profile — a navigation would reload the page under the reader, so the press
// is taken here and the composer opened in place, through the same
// `focusComposer` the "n" shortcut uses, which clicks that page's (hidden, on
// a phone) compose button and focuses the editor.
//
// Registered before app.js's own click listeners, as every import is, which is
// what lets the nav press paint see `defaultPrevented` and leave this press
// unpainted: nothing is navigating.

import { focusComposer } from "./keyboard_shortcuts"
import { plainClick } from "./util"

document.addEventListener("click", (event) => {
  // A modified click opens the feed in a new tab, where the reader really is
  // asking for the page.
  if (!plainClick(event)) return

  const tab = event.target.closest?.("a[data-mobile-compose]")
  if (!tab) return

  if (focusComposer()) event.preventDefault()
})
