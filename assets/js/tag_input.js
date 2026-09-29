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
// The comma is still nothing a member has to know: Enter and Tab finish a tag
// too, and the list under the box (tag_suggest.js) offers
// the topics that already exist, with how many members carry them.
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

import { attachTagSuggest, foldTagName, formatCount } from "./tag_suggest"

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

// The keys that finish the tag being typed, in both tag fields: Enter and Tab,
// so nobody has to know about the comma. Shift+Tab keeps walking back.
const finishesTag = (e) => e.key === "Enter" || (e.key === "Tab" && !e.shiftKey)

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
  // How many pills this box takes, and what it says once it is full. Both come
  // from the server (`<.tag_input max={…}>`), so the number lives beside the
  // rule that enforces it and the sentence is translated — a post takes five
  // tags, every other tag field on the site takes as many as you type.
  const parsedMax = parseInt(root.dataset.max || "", 10)
  const limit = Number.isInteger(parsedMax) && parsedMax > 0 ? parsedMax : null
  const limitMessage = root.dataset.limitMessage || ""
  const sent = []
  let tags = []
  // What each pill's name resolves to: `{name, count}` by folded name, filled
  // from the suggestion answers and, for a pill that came some other way, by
  // asking (`resolvePills`).
  const known = new Map()

  const box = document.createElement("div")
  box.className = "tag-input__box"

  const entry = document.createElement("input")
  entry.type = "text"
  entry.className = "tag-input__entry"
  entry.setAttribute("autocomplete", "off")

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

  // The line that says why the next tag will not go in. It is built even for an
  // uncapped box and left empty: a live region has to be in the DOM before its
  // text appears, or a screen reader never announces it.
  const notice = document.createElement("p")
  notice.className = "tag-input__notice"
  notice.setAttribute("role", "status")
  notice.hidden = true

  field.type = "hidden"
  field.insertAdjacentElement("afterend", box)
  box.appendChild(entry)
  box.insertAdjacentElement("afterend", notice)
  root.classList.add("tag-input--enhanced")

  // The list of existing topics under the box (tag_suggest.js); null where the
  // page carries no suggestion address, and the box then works as it always did.
  const suggest = attachTagSuggest(entry, {
    // Inside the box, which positions it (components.css); the root is
    // `phx-update="ignore"`, so nothing patches it away.
    place: (list) => box.appendChild(list),
    source: root,
    // Only the tag still being typed, and nothing once the box is full: a list
    // of topics the box would refuse is an offer it cannot keep.
    query: () => (isFull() ? "" : entry.value.split(SEPARATOR).pop()),
    taken: () => tags,
    onPick: (name, row) => {
      known.set(foldTagName(name), { name, count: row.count })
      const parts = entry.value.split(SEPARATOR)
      parts.pop()
      entry.value = parts.concat([name]).join(",")
      commitPending()
    },
  })

  function renderPills() {
    box.querySelectorAll("[data-tag-pill]").forEach((pill) => pill.remove())

    tags.forEach((tag, index) => {
      const pill = document.createElement("span")
      pill.className = "tag-input__pill"
      pill.setAttribute("data-tag-pill", tag)

      const label = document.createElement("span")
      label.className = "tag-input__name"
      label.textContent = tag

      // How many members carry it, once that is known: the reason to pick an
      // existing topic over a new spelling is visible on the pill itself.
      const count = document.createElement("span")
      count.className = "tag-input__count"
      const info = known.get(foldTagName(tag))
      if (info && info.count > 0) count.textContent = formatCount(info.count)
      else count.hidden = true

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "tag-input__remove"
      remove.setAttribute("aria-label", removeLabel.replace("%{name}", tag))
      remove.textContent = "×"
      // Removing must not go through a blur first: the blur handler re-renders
      // the pills, and a button detached between mousedown and mouseup never
      // fires its click.
      remove.addEventListener("mousedown", (e) => e.preventDefault())
      remove.addEventListener("click", () => {
        tags.splice(index, 1)
        renderPills()
        updateNotice()
        sync()
        entry.focus()
      })

      pill.append(label, count, remove)
      box.insertBefore(pill, entry)
    })

    entry.placeholder = tags.length ? morePlaceholder : placeholder
    resolvePills()
  }

  // A pill that arrived without the list (a comma, a paste, a restored draft)
  // is asked about once: it takes the name of the topic it will be saved as
  // ("js" turns into javascript, as the save would do anyway) and its count.
  function resolvePills() {
    if (!suggest) return
    const unknown = tags.filter((tag) => !known.has(foldTagName(tag)))
    if (unknown.length === 0) return
    // Asked once, answered or not: a name the answer leaves out must not send
    // the next render asking again, and again.
    unknown.forEach((tag) => known.set(foldTagName(tag), null))

    suggest
      .counts(unknown)
      .then((answers) => {
        let changed = false
        answers.forEach((answer, key) => {
          known.set(key, answer)
          known.set(foldTagName(answer.name), answer)
        })
        tags = tags.reduce((out, tag) => {
          const answer = answers.get(foldTagName(tag))
          const name = answer ? answer.name : tag
          if (name !== tag) changed = true
          if (!out.some((t) => foldTagName(t) === foldTagName(name))) out.push(name)
          else changed = true
          return out
        }, [])
        renderPills()
        if (changed) sync()
      })
      .catch(() => {})
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

  // Say why nothing more goes in, for as long as that is true. Shown the moment
  // the box fills rather than only on the refusal, so the limit is visible
  // before it bites — and cleared by taking a pill back out.
  function isFull() {
    return limit !== null && tags.length >= limit
  }

  function updateNotice() {
    const full = isFull()
    notice.textContent = full ? limitMessage : ""
    notice.hidden = !full || limitMessage === ""
  }

  // Take one typed value into the pills, answering what became of it. The
  // caller has to know: a value the cap refuses is kept in the entry, because
  // dropping it is the silent loss this whole box exists to prevent (#1237).
  function add(value) {
    const name = normalizeTag(value)
    if (!name) return "skipped"
    // Case-insensitive, like the server's dedupe — two pills reading the same
    // thing would promise a tag the save then collapses.
    if (tags.some((tag) => foldTagName(tag) === foldTagName(name))) return "skipped"
    if (isFull()) return "full"
    tags.push(name)
    return "added"
  }

  // Add a run of finished values; returns the ones that did not fit. The first
  // refusal stops the run, so what stays in the entry reads in the order it was
  // typed rather than with the tags that happened to fit plucked out of it.
  function addAll(values) {
    const leftover = []

    values.forEach((value) => {
      const name = normalizeTag(value)
      if (!name) return
      if (leftover.length > 0 || add(name) === "full") leftover.push(name)
    })

    return leftover
  }

  function commitPending() {
    if (!entry.value.trim()) {
      entry.value = ""
      updateNotice()
      return
    }
    entry.value = addAll(splitTags(entry.value)).join(", ")
    renderPills()
    updateNotice()
    sync()
  }

  entry.addEventListener("input", () => {
    const raw = entry.value.replace(HASHTAG_START, ",#")

    if (SEPARATOR.test(raw)) {
      const parts = raw.split(SEPARATOR)
      // Everything before the last separator is finished; the tail stays in the
      // box as the tag still being typed (without the space after the comma,
      // which would otherwise sit in front of the caret). Anything the cap
      // refused waits in front of that tail instead of disappearing — and keeps
      // its comma, or the next thing typed runs into it and the two read as one
      // tag ("LiveView Tailwind" for two refused names, caught in a browser).
      const tail = parts.pop().replace(/^\s+/, "")
      const leftover = addAll(parts)

      entry.value = leftover.length
        ? [leftover.join(", ") + ",", tail].filter(Boolean).join(" ")
        : tail

      renderPills()
    }

    updateNotice()
    sync()
    suggest?.refresh()
  })

  entry.addEventListener("keydown", (e) => {
    // An open list takes its keys first (arrows, Enter and Tab pick, Escape
    // closes); what it leaves alone falls through to the box.
    if (suggest?.keydown(e)) return

    if (finishesTag(e)) {
      // Enter and Tab finish the tag being typed, so nobody has to know about
      // the comma. On an empty box both keep their ordinary meaning: Enter
      // submits the form, Tab moves on to the next field.
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
      updateNotice()
      sync()
    }
  })

  // Leaving the box only closes the list. `sync()` already carries the word
  // still being typed into the form field, so a submit keeps it; turning it
  // into a pill on blur could wrap the box onto a new row between the mousedown
  // and the mouseup of a click on the button below, and that click then landed
  // on nothing (found on the sign-up form, which shares this rule).
  entry.addEventListener("blur", () => suggest?.close())

  // The box looks like one input, so a click anywhere in it lands in the entry.
  box.addEventListener("click", (e) => {
    if (!e.target.closest("button")) entry.focus()
  })

  function reseed(value) {
    tags = []
    // Through the same gate as typing: a restored draft can carry more tags
    // than the box takes, and the ones past the cap belong in the entry (where
    // their member can still see and edit them), not in a sixth pill.
    const leftover = addAll(splitTags(value))
    entry.value = leftover.join(", ")
    field.value = tags.concat(leftover).join(", ")
    sent.length = 0
    renderPills()
    updateNotice()
  }

  // Seed from what the server rendered, through the same gate as typing — so a
  // value that arrives over the cap shows its overflow in the entry rather than
  // as pills the box promised to keep and the save then refuses.
  entry.value = addAll(splitTags(field.value)).join(", ")
  renderPills()
  updateNotice()

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

// The sign-up form's tag field. Its pills are the server's (they carry member
// counts and feed the three-tag rule), so this hook only finishes tags and
// tells `VutuvWeb.RegistrationLive` about them: a comma, Enter, Tab or a pick
// from the suggestion list, the same ways the shared box above finishes one.
//
// The browser has to be the one that shortens the field. LiveView deliberately
// never overwrites the value of a FOCUSED input (it would throw away what
// somebody is in the middle of typing), so a server that clears the field has
// no effect while the cursor is still in it, and "Hund," stays on screen beside
// the badge it just became. So the hook cuts the finished part out of the DOM
// value and tells the server both halves in one event: what was finished, and
// what it left standing. It reads only its own input, never the server's echo,
// so the late-echo trap the composer's editor documents cannot form here.
export const TagComma = {
  mounted() {
    const el = this.el
    const finish = (value, rest = "") => {
      el.value = rest
      this.pushEvent("add_typed", { value, rest })
    }

    const suggest = attachTagSuggest(el, {
      place: (list) => document.getElementById(`${el.id}-suggest`)?.append(list),
      source: el,
      query: () => el.value,
      taken: () =>
        [...(el.closest(".tag-input__box")?.querySelectorAll("[data-tag-pill]") || [])].map(
          (pill) => pill.dataset.tagPill,
        ),
      onPick: (name) => finish(name),
    })

    el.addEventListener("input", () => {
      if (el.value.includes(",")) {
        const parts = el.value.split(",")
        const rest = parts.pop().replace(/^\s+/, "")
        finish(parts.join(","), rest)
      }
      suggest?.refresh()
    })

    el.addEventListener("keydown", (e) => {
      if (suggest?.keydown(e)) return
      // Enter or Tab with a tag in the field finishes that tag and does nothing
      // else: the whole wizard is one form, and an Enter meant for a tag must
      // not submit it. On an empty field both keep their ordinary meaning.
      if (finishesTag(e) && el.value.trim()) {
        e.preventDefault()
        finish(el.value)
      }
    })

    // Leaving the field only closes the list. The server already counts and
    // submits what is still typed (`RegistrationLive.refresh_submitted_tags/1`);
    // turning it into a pill here as well grew the box by a row between the
    // mousedown and the mouseup of a click on the submit button below, and
    // that click landed on nothing.
    el.addEventListener("blur", () => suggest?.close())
  },
}
