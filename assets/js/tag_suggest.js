// The suggestion list under every tag field: existing topics, with how many
// members carry them, offered while a member types a tag.
//
// Why it exists: the pill box made a finished tag visible, but finishing one
// still took a comma nobody guesses, and a topic typed from memory ("JS",
// "Javascript", "java script") became a new tag beside the one hundreds of
// members already carry. The list answers both: Enter or Tab finishes a tag,
// and the topics that already exist are one arrow key away.
//
// The first row is always what was typed, resolved to the topic it would be
// saved as. So Enter never takes something the member did not type, and "js"
// already reads as the javascript it is going to become. The rows below it are
// the topics the typed text starts (`Vutuv.Tags.suggest/2`, served by
// `VutuvWeb.TagSuggestController`).
//
// One list for two owners. The shared pill box (tag_input.js) owns its pills
// in the browser; the sign-up form (the `TagComma` hook) owns them on the
// server. Both hand this module the entry, the element to hang the list under
// and what a pick does, and keep everything else. The key handling and the
// active-row marking are the editor's (suggest_list.js), so every suggestion
// list on the site answers the keys the same way.

import { markActiveRow, stepIndex, suggestKey } from "./suggest_list"
import { getJSON, request } from "./util"

const DEBOUNCE_MS = 120
// A typed prefix asked once is not asked again while the page lives: a member
// who deletes a letter and types it again gets the answer from memory.
const CACHE_LIMIT = 200
let listCount = 0

// What the server translated for us, read once from the element carrying the
// `data-tag-suggest-*` attributes (`VutuvWeb.UI.tag_suggest_attrs/0`).
function readLabels(el) {
  const d = el.dataset
  return {
    url: d.tagSuggestUrl,
    newTag: d.tagSuggestNew || "%{name}",
    taken: d.tagSuggestTaken || "",
    alias: d.tagSuggestAlias || "%{name}",
    one: d.tagSuggestMembersOne || "%{formatted}",
    other: d.tagSuggestMembersOther || "%{formatted}",
  }
}

// The client's half of `Vutuv.Tags.MatchKey.normalize/1`, kept to the same
// steps (zero-width characters out, case-folded, separator runs to one `-`,
// trimmed of `-`): two names that fold alike are one topic, so the list and the
// pills compare through this. Keep the two in step.
export const foldTagName = (name) =>
  String(name || "")
    .replace(/[\u0000​‌‍﻿]/g, "")
    .toLowerCase()
    .replace(/[\s_-]+/g, "-")
    .replace(/^-+|-+$/g, "")

// A member count in the page's language (60.023 in German, 60,023 in English),
// never a run-together integer.
export function formatCount(count) {
  try {
    return new Intl.NumberFormat(document.documentElement.lang || undefined).format(count)
  } catch (_e) {
    return new Intl.NumberFormat().format(count)
  }
}

// `count` members, said the way the server's gettext says it.
function membersLabel(labels, count) {
  const template = count === 1 ? labels.one : labels.other
  return template.replace("%{formatted}", formatCount(count))
}

// Attach the list to `entry`.
//
//   place   (list) => put the list into the page, under the box the entry
//           sits in; inside a LiveView somewhere morphdom leaves alone
//   source  the element carrying the `data-tag-suggest-*` attributes
//   query   () => the text being typed, without any finished part before it
//   taken   () => the names already chosen, so the list does not offer them
//   onPick  (name, row) => take that name as a tag; `row` carries its count
//
// Returns `{ keydown, refresh, close, counts }`. `keydown` answers whether it
// took the key; the caller runs its own handling only when it did not.
export function attachTagSuggest(entry, { place, source, query, taken, onPick }) {
  const labels = readLabels(source)
  if (!labels.url) return null

  const cache = new Map()
  const list = document.createElement("ul")
  list.className = "tag-suggest"
  list.id = `tag-suggest-${++listCount}`
  list.setAttribute("role", "listbox")
  list.hidden = true
  place(list)

  entry.setAttribute("role", "combobox")
  entry.setAttribute("aria-autocomplete", "list")
  entry.setAttribute("aria-controls", list.id)
  entry.setAttribute("aria-expanded", "false")

  let rows = []
  let active = 0
  let timer = null
  let controller = null

  function remember(key, value) {
    cache.set(key, value)
    if (cache.size > CACHE_LIMIT) cache.delete(cache.keys().next().value)
  }

  // `request/2` rather than `getJSON/2`: only this one needs the abort, since
  // the answer to "ja" must not land after the one to "jav".
  async function fetchSuggestions(q) {
    controller?.abort()
    controller = new AbortController()
    const response = await request(`${labels.url}?${new URLSearchParams({ q })}`, {
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`tag suggest ${response.status}`)
    return response.json()
  }

  function close() {
    clearTimeout(timer)
    rows = []
    list.hidden = true
    list.replaceChildren()
    entry.setAttribute("aria-expanded", "false")
    entry.removeAttribute("aria-activedescendant")
  }

  function isTaken(name) {
    const key = foldTagName(name)
    return taken().some((t) => foldTagName(t) === key)
  }

  // One row. Built from DOM nodes rather than markup: the names are whatever
  // members typed, and none of it may be read as HTML.
  function rowElement(row, index, q) {
    const li = document.createElement("li")
    li.id = `${list.id}-${index}`
    li.className = "tag-suggest__row"
    li.setAttribute("role", "option")
    li.dataset.index = index

    const text = document.createElement("span")
    text.className = "tag-suggest__text"
    const name = document.createElement("span")
    name.className = "tag-suggest__name"

    if (row.typed && !row.count && foldTagName(row.name) === foldTagName(q)) {
      name.textContent = labels.newTag.replace("%{name}", row.name)
      name.classList.add("tag-suggest__name--new")
    } else {
      highlight(name, row.name, q)
    }
    text.append(name)

    const note = row.taken ? labels.taken : row.alias ? labels.alias.replace("%{name}", row.alias) : ""
    if (note) {
      const small = document.createElement("span")
      small.className = "tag-suggest__note"
      small.textContent = note
      text.append(small)
    }
    li.append(text)

    if (row.count > 0) {
      const count = document.createElement("span")
      count.className = "tag-suggest__count"
      count.textContent = membersLabel(labels, row.count)
      li.append(count)
    }

    return li
  }

  function highlight(target, name, q) {
    const at = name.toLowerCase().indexOf(q.toLowerCase())
    if (!q || at < 0) {
      target.textContent = name
      return
    }
    const mark = document.createElement("mark")
    mark.textContent = name.slice(at, at + q.length)
    target.append(name.slice(0, at), mark, name.slice(at + q.length))
  }

  function show(answer, q) {
    if (!answer.typed || document.activeElement !== entry) return close()

    // The typed row names what the member will get: the topic, if what they
    // typed is another name for one ("js" is javascript), with that name noted.
    const typedAlias = foldTagName(answer.typed.name) === foldTagName(q) ? null : q
    rows = [{ ...answer.typed, typed: true, alias: typedAlias, taken: isTaken(answer.typed.name) }].concat(
      answer.results.filter((r) => !isTaken(r.name)),
    )
    active = 0
    list.replaceChildren(...rows.map((row, i) => rowElement(row, i, q)))
    list.hidden = false
    entry.setAttribute("aria-expanded", "true")
    markActiveRow([...list.children], active, entry)
  }

  function refresh() {
    clearTimeout(timer)
    const q = query().trim()
    if (!q) return close()

    const key = foldTagName(q)
    if (cache.has(key)) return show(cache.get(key), q)

    timer = setTimeout(async () => {
      try {
        const answer = await fetchSuggestions(q)
        remember(key, answer)
        // The typed row is the answer a pill made from this text would ask
        // for, so a Tab or Enter that commits it needs no second request.
        if (answer.typed) remember(`=${key}`, { typed: q, ...answer.typed })
        // Only if the member is still typing the same thing: an answer that
        // arrives after the next letter would put an old list under new text.
        if (foldTagName(query().trim()) === key) show(answer, q)
      } catch (e) {
        // An aborted request is simply superseded; anything else means no
        // list, and the field goes on working exactly as it did without one.
        if (e.name !== "AbortError") close()
      }
    }, DEBOUNCE_MS)
  }

  function pick(index) {
    const row = rows[index]
    if (!row) return false
    close()
    onPick(row.name, row)
    return true
  }

  function keydown(event) {
    if (list.hidden || rows.length === 0) return false

    const handled = suggestKey(event, {
      move: (delta) => {
        active = stepIndex(active, delta, rows.length)
        markActiveRow([...list.children], active, entry)
      },
      accept: () => pick(active),
      dismiss: close,
    })

    if (handled) event.preventDefault()
    return handled
  }

  // A pick must not blur the entry first: the owner commits on blur, and the
  // half-typed text would land as a tag before the picked one.
  list.addEventListener("mousedown", (e) => e.preventDefault())
  list.addEventListener("click", (e) => {
    const row = e.target.closest(".tag-suggest__row")
    if (row) pick(Number(row.dataset.index))
    entry.focus()
  })
  list.addEventListener("mousemove", (e) => {
    const row = e.target.closest(".tag-suggest__row")
    if (!row || Number(row.dataset.index) === active) return
    active = Number(row.dataset.index)
    markActiveRow([...list.children], active, entry)
  })

  // Which topic each name becomes and how many members carry it, for pills the
  // box got without asking (a comma, a paste, a restored draft). Answers a Map
  // keyed by the folded name as it was typed.
  async function counts(names) {
    const out = new Map()
    const missing = []
    names.forEach((n) => {
      const hit = cache.get(`=${foldTagName(n)}`)
      if (hit) out.set(foldTagName(n), hit)
      else missing.push(n)
    })
    if (missing.length === 0) return out

    const body = await getJSON(labels.url, { names: missing.join(",") })
    body?.counts.forEach((c) => {
      remember(`=${foldTagName(c.typed)}`, c)
      out.set(foldTagName(c.typed), c)
    })
    return out
  }

  return { keydown, refresh, close, counts }
}
