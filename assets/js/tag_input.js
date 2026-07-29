// The tag pill box: one enhancement for every field where a member types a
// batch of tags — the add-tag form, the sign-up landing page, the invitation
// form, the post composer and the job posting form.
//
// Why it exists: a comma, and nothing else, separates two tags
// (`Vutuv.Tags.parse_tag_names/1`). A plain text box shows no seam between one
// tag and the next, so members read the space as a separator too and ended up
// with tags they never meant to create. Here every finished tag becomes a pill
// the moment its comma is typed, and each pill has its own ✕ — so the rule is
// visible in the box instead of explained in a hint nobody reads.
//
// This is progressive enhancement, not a widget: the server renders one
// ordinary `<input type="text">` holding the comma-joined value, and with JS
// off that input IS the feature. The enhancement switches it to `hidden`
// (keeping it as the form field, so nothing about the request or the server
// changes), builds the pill box beside it, and mirrors every change back into
// it — including the half-typed tail — so a submit at any moment carries
// exactly what the box shows.
//
// Both page styles are served from here: a LiveView mounts it through the
// `TagInput` hook, a classic controller page through the `[data-tag-input]`
// sweep in app.js. On a LiveView the root is `phx-update="ignore"` (the pills
// are ours; morphdom must not touch them) while its ATTRIBUTES still patch,
// which is how a server-driven value change reaches us: `data-value` mirrors
// the assign and `updated()` re-seeds the pills whenever it carries something
// we did not send ourselves (a restored draft, the composer clearing after a
// post). Values we did send come back to us on every keystroke, so they are
// remembered and ignored — re-seeding on one would yank half-typed text away.

// Straight, curly, German and guillemet quotes. Quoting used to be how a
// multi-word tag was grouped; multi-word is the default now, so a quote carries
// no meaning and is dropped — mirroring `Vutuv.Tags.parse_tag_names/1`.
const QUOTES = /["“”„‟«»]/g
// A `#` that starts a word begins a new tag, so a pasted run of hashtags splits;
// a `#` inside a word is part of the name, so `C#` stays whole.
const HASHTAG_START = /\s+#/g
const SEPARATOR = /[,\r\n]/
const SEPARATORS = /[,\r\n]+/
// How many recently-sent values to remember (see maybeReseed): a handful covers
// any round trip in flight, and the list must not grow with every keystroke.
const SENT_MEMORY = 30

// One tag name, cleaned the way `Vutuv.Tags.Tag.normalize_value/1` cleans it:
// trimmed, a leading `#` run removed, interior whitespace collapsed.
export function normalizeTag(value) {
  return String(value || "")
    .replace(QUOTES, "")
    .trim()
    .replace(/^#+\s*/, "")
    .replace(/\s+/g, " ")
    .trim()
}

// Split a typed batch into clean tag names — the client-side twin of
// `Vutuv.Tags.parse_tag_names/1`. Keep the two in step.
export function splitTags(text) {
  return String(text || "")
    .replace(QUOTES, "")
    .replace(HASHTAG_START, ",#")
    .split(SEPARATORS)
    .map(normalizeTag)
    .filter(Boolean)
}

// Enhance one `[data-tag-input]` root. Idempotent: the API is parked on the
// element, so the app.js sweep and the LiveView hook can both ask for it.
export function enhanceTagInput(root) {
  if (root.tagInput) return root.tagInput
  const field = root.querySelector("[data-tag-input-field]")
  if (!field) return null
  root.tagInput = build(root, field)
  return root.tagInput
}

function build(root, field) {
  const placeholder = field.getAttribute("placeholder") || ""
  const morePlaceholder = root.dataset.morePlaceholder || ""
  const removeLabel = root.dataset.removeLabel || "Remove"
  const sent = []
  let tags = splitTags(field.value)

  const box = document.createElement("div")
  box.className = "tag-input__box"

  const entry = document.createElement("input")
  entry.type = "text"
  entry.className = "tag-input__entry"
  entry.setAttribute("autocomplete", "off")
  entry.setAttribute("data-tag-input-entry", "")

  // The label and any error message point at the field's id, so the id moves to
  // the box the member actually types in; a `for` aimed at a hidden input would
  // leave the field unlabelled.
  const id = field.getAttribute("id")
  if (id) {
    field.removeAttribute("id")
    entry.id = id
  }
  ;["aria-invalid", "aria-describedby", "aria-label"].forEach((name) => {
    const value = field.getAttribute(name)
    if (value !== null) entry.setAttribute(name, value)
  })

  field.type = "hidden"
  field.insertAdjacentElement("afterend", box)
  box.appendChild(entry)
  root.classList.add("tag-input--enhanced")

  function renderPills() {
    box.querySelectorAll("[data-tag-pill]").forEach((pill) => pill.remove())

    tags.forEach((tag, index) => {
      const pill = document.createElement("span")
      pill.className = "tag-input__pill"
      pill.setAttribute("data-tag-pill", tag)

      const label = document.createElement("span")
      label.className = "tag-input__name"
      label.textContent = tag

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "tag-input__remove"
      remove.setAttribute("data-tag-remove", "")
      remove.setAttribute("aria-label", removeLabel.replace("%{name}", tag))
      remove.textContent = "×"
      // Removing must not go through a blur first: the blur handler re-renders
      // the pills, and a button detached between mousedown and mouseup never
      // fires its click.
      remove.addEventListener("mousedown", (e) => e.preventDefault())
      remove.addEventListener("click", () => {
        tags.splice(index, 1)
        renderPills()
        sync()
        entry.focus()
      })

      pill.append(label, remove)
      box.insertBefore(pill, entry)
    })

    entry.placeholder = tags.length ? morePlaceholder : placeholder
  }

  // Mirror the box into the real form field: the committed pills plus whatever
  // is still being typed, so a submit mid-word keeps that word.
  function sync() {
    const pending = entry.value.trim()
    const next = (pending ? tags.concat([pending]) : tags).join(", ")
    if (field.value === next) return

    field.value = next
    sent.push(next)
    if (sent.length > SENT_MEMORY) sent.shift()
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  function add(value) {
    const name = normalizeTag(value)
    if (!name) return
    // Case-insensitive, like the server's dedupe — two pills reading the same
    // thing would promise a tag the save then collapses.
    if (tags.some((tag) => tag.toLowerCase() === name.toLowerCase())) return
    tags.push(name)
  }

  function commitPending() {
    if (!entry.value.trim()) {
      entry.value = ""
      return
    }
    add(entry.value)
    entry.value = ""
    renderPills()
    sync()
  }

  entry.addEventListener("input", () => {
    const raw = entry.value.replace(HASHTAG_START, ",#")

    if (SEPARATOR.test(raw)) {
      const parts = raw.split(SEPARATOR)
      // Everything before the last separator is finished; the tail stays in the
      // box as the tag still being typed (without the space after the comma,
      // which would otherwise sit in front of the caret).
      const tail = parts.pop()
      parts.forEach(add)
      entry.value = tail.replace(/^\s+/, "")
      renderPills()
    }

    sync()
  })

  entry.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      // Enter finishes the tag being typed; on an empty box it belongs to the
      // form, so a member can still submit from here.
      if (entry.value.trim()) {
        e.preventDefault()
        commitPending()
      }
    } else if (e.key === "Backspace" && entry.value === "" && tags.length) {
      // Backspace on an empty box takes the last pill back apart for editing
      // rather than dropping it silently.
      e.preventDefault()
      entry.value = tags.pop()
      renderPills()
      sync()
    }
  })

  entry.addEventListener("blur", commitPending)

  // The box looks like one input, so a click anywhere in it lands in the entry.
  box.addEventListener("click", (e) => {
    if (!e.target.closest("button")) entry.focus()
  })

  function reseed(value) {
    tags = splitTags(value)
    entry.value = ""
    field.value = tags.join(", ")
    sent.length = 0
    renderPills()
  }

  renderPills()

  return {
    reseed,
    // Decide whether a server-rendered value is news. Two things it is not:
    // what the box already holds (an unrelated re-render), and a value we sent
    // ourselves that is only now coming back — the LiveView echoes every
    // keystroke, and re-seeding on a debounced echo would swallow whatever was
    // typed since. A matched echo is CONSUMED along with everything older than
    // it: those can no longer arrive, and leaving them behind is what once made
    // a genuine server reset to "" (the composer clearing after a post) look
    // like an echo of the empty box the member started from.
    maybeReseed(value) {
      if (value === field.value) return

      const seen = sent.lastIndexOf(value)
      if (seen !== -1) {
        sent.splice(0, seen + 1)
        return
      }

      reseed(value)
    },
  }
}

export const TagInput = {
  mounted() {
    enhanceTagInput(this.el)
  },
  updated() {
    this.el.tagInput?.maybeReseed(this.el.dataset.value || "")
  },
}
