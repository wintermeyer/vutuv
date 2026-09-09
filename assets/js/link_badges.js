// The media kit's "Link to your profile" card (/system/media-kit): typing a
// handle rewrites every copy-and-paste snippet on the card, so what the member
// copies is their own address rather than a placeholder they have to remember
// to edit.
//
// Progressive enhancement, and the un-enhanced page is the whole feature minus
// the typing: the server already fills a signed-in member's own handle into
// every snippet, so this is only load-bearing for a visitor who is not signed
// in — which is why the field ships `hidden` and is revealed here.
//
// Each snippet wrapper carries `data-snippet`, the template with the server's
// `__HANDLE__` token still in it. Rewriting from the template rather than
// replacing the old handle in the rendered text is what keeps a handle that is
// a substring of something else on the line (a member called "vutuv", or "de")
// from tearing the host apart.
import { normalizeHandle, once, onReady } from "./util"

const TOKEN = "__HANDLE__"

// What a handle is allowed to be, from `Vutuv.Handles`: lower-case letters,
// digits and underscores, up to its 23-character cap. Anything else cannot name
// a member here, so it is a typo rather than an address, and the snippets fall
// back to the placeholder rather than handing out a link that goes nowhere.
// Deliberately without the 3-character minimum the server also enforces: every
// prefix of a handle passes through this on the way to being typed, and a field
// that flickers back to the placeholder for the first two keystrokes reads as
// broken.
const HANDLE = /^[a-z0-9_]{1,23}$/

// What somebody is likely to paste: their own profile address, which is what a
// member has in their clipboard. Take the last path segment ONLY when the URL
// is one of ours — the standing rule here is that "is this us" is decided on
// the host, never on the shape of the string. Without that check a pasted
// `https://mastodon.social/@someone` would quietly become a *vutuv* link to
// whoever holds `someone` here, which is the outcome the `__HANDLE__` token
// exists to prevent. A foreign address yields nothing at all rather than its
// own last segment, for the same reason.
function handleFrom(value) {
  const trimmed = value.trim()

  try {
    const url = new URL(trimmed)
    if (url.host !== location.host) return ""
    return url.pathname.split("/").filter(Boolean).pop() || ""
  } catch {
    // Not a URL at all, which is the ordinary case: somebody typed a handle.
    return trimmed
  }
}

function wireCard(card) {
  if (!once(card, "linkBadges")) return

  const field = card.querySelector("[data-handle-field]")
  const input = field && field.querySelector("input")
  if (!input) return

  // The server-rendered value, which never changes as the member types, so it
  // is also the fallback for an emptied field.
  const placeholder = input.defaultValue
  const snippets = [...card.querySelectorAll("[data-snippet]")]
    .map((el) => ({ template: el.dataset.snippet, code: el.querySelector("code") }))
    .filter(({ code }) => code)

  const render = () => {
    const typed = normalizeHandle(handleFrom(input.value))
    const handle = HANDLE.test(typed) ? typed : placeholder
    snippets.forEach(({ template, code }) => {
      code.textContent = template.replaceAll(TOKEN, handle)
    })
  }

  input.addEventListener("input", render)
  field.hidden = false
}

onReady(() => document.querySelectorAll("[data-link-badges]").forEach(wireCard))
