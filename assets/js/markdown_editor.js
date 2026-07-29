// Milkdown-based Markdown editor, shared by the post composer and the message
// composer (see VutuvWeb.UI.markdown_editor/1). It is a WYSIWYG surface over a
// plain Markdown store: the form field stays a `<textarea>` holding Markdown
// source, and Milkdown renders/edits that Markdown in place. So nothing in the
// server pipeline changes — VutuvWeb.Markdown still renders the stored source,
// and the .md/.txt/.json/.xml siblings keep working.
//
// Three surfaces share one hidden textarea (the form field):
//   * WYSIWYG (default for everyone) — the Milkdown editor.
//   * Source (opt-in, for power users) — the raw Markdown textarea, toggled from
//     the toolbar; edits there flow straight to the form field.
//   * No-JS fallback — with the hook unmounted, CSS shows the plain textarea.
//
// The enabled Markdown features are deliberately a subset that matches exactly
// what VutuvWeb.Markdown renders: bold, italic, strikethrough, links, bullet /
// ordered / nested lists, headings, blockquote, inline + fenced code, tables and
// horizontal rules. Task-list checkboxes are intentionally excluded — Earmark
// renders them as literal "[ ]" text, so offering them would be a dishonest
// WYSIWYG. Milkdown's gfm() preset bundles task lists, so we compose the gfm
// pieces we want by hand rather than using the whole preset.
//
// Images are policy-gated: only the post composer enables them
// (data-mde-images), and even there an image node survives only when its src is
// an own-upload proxy URL (`/post_images/…`) — mirroring the server, where
// VutuvWeb.Markdown renders exactly those references and drops everything else
// (a hotlinked remote picture would leak every reader's IP). Message and other
// bodies keep stripping every image node. Upload flow: a file dropped or pasted
// into the prose (or picked via the 🖼 toolbar button) is forwarded to the
// form's LiveView file input; the server processes it eagerly and answers with
// an `mde-image-uploaded` push event, at which point the hook inserts the image
// at the remembered cursor position. The thumbnail row's "Insert" button pushes
// `mde-insert-image` for an explicit at-cursor insert. An image's alignment
// lives as a `#left`/`#right`/`#center` src fragment (no fragment = full
// width), edited via the toolbar's img-* buttons while an image is selected.
import { Editor, rootCtx, defaultValueCtx, editorViewCtx } from "@milkdown/kit/core"
import {
  commonmark,
  toggleStrongCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleLinkCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
  wrapInHeadingCommand,
  wrapInBlockquoteCommand,
  createCodeBlockCommand,
  insertHrCommand,
} from "@milkdown/kit/preset/commonmark"
import * as gfm from "@milkdown/kit/preset/gfm"
import { listener, listenerCtx } from "@milkdown/kit/plugin/listener"
import { history } from "@milkdown/kit/plugin/history"
import { callCommand, getMarkdown, replaceAll } from "@milkdown/kit/utils"
import { $prose } from "@milkdown/kit/utils"
import {
  Plugin,
  PluginKey,
  NodeSelection,
  TextSelection,
} from "@milkdown/kit/prose/state"
import { Decoration, DecorationSet } from "@milkdown/kit/prose/view"

// The gfm bits we want, minus task lists (extendListItemSchemaForTask +
// wrapInTaskListInputRule), which the server renders as literal "[ ]" text, and
// minus footnotes. The server DOES render footnotes (issue #1147), but from the
// Markdown source: `[^1]` and its `[^1]: note` line stay ordinary text in the
// editor, the way a member typing them expects, and the whole feature costs the
// composer two string transforms instead of a node type, a keymap and an input
// rule that could corrupt a body on a round trip. See escapeFootnotes /
// canonicalizeFootnotes below for the two things that DO have to happen.
// remarkGFMPlugin is what teaches the Markdown parser/serializer about `~~`
// strikethrough and `| pipe |` tables, so it has to stay.
const strikethrough = [
  gfm.strikethroughAttr,
  gfm.strikethroughSchema,
  gfm.strikethroughInputRule,
  gfm.strikethroughKeymap,
  gfm.toggleStrikethroughCommand,
]

const table = [
  gfm.tableSchema,
  gfm.tableHeaderRowSchema,
  gfm.tableRowSchema,
  gfm.tableHeaderSchema,
  gfm.tableCellSchema,
  gfm.insertTableInputRule,
  gfm.tablePasteRule,
  gfm.tableKeymap,
  gfm.insertTableCommand,
  gfm.goToNextTableCellCommand,
  gfm.goToPrevTableCellCommand,
  gfm.exitTable,
  gfm.addRowAfterCommand,
  gfm.addColAfterCommand,
  gfm.keepTableAlignPlugin,
  gfm.tableEditingPlugin,
]

const gfmSubset = [gfm.remarkGFMPlugin, ...strikethrough, ...table].flat()

// A no-dependency placeholder: decorate the sole empty paragraph so CSS can
// paint the prompt text (::before reads data-placeholder). Milkdown ships no
// placeholder plugin, and this keeps it a pure decoration (never real content).
const placeholder = (text) =>
  $prose(
    () =>
      new Plugin({
        key: new PluginKey("MDE_PLACEHOLDER"),
        props: {
          decorations(state) {
            const { doc } = state
            const empty =
              doc.childCount === 1 &&
              doc.firstChild.isTextblock &&
              doc.firstChild.content.size === 0
            if (!empty) return null
            return DecorationSet.create(doc, [
              Decoration.node(0, doc.firstChild.nodeSize, {
                class: "mde-placeholder",
                "data-placeholder": text,
              }),
            ])
          },
        },
      })
  )

// The image src forms the server renders: an own-upload proxy URL, optionally
// with an alignment fragment. Everything else is deleted from the prose so the
// WYSIWYG never shows an image the rendered post would silently omit.
const OWN_IMAGE_SRC = /^\/post_images\/[A-Za-z0-9_-]+\/(thumb|feed|large)\.(avif|webp)(#(left|right|center))?$/

// Image policy: with images disabled (messages, org/job descriptions) every
// image node is stripped — commonmark bundles the node type, so a pasted
// picture or a typed `![alt](src)` would otherwise create one. With images
// enabled (the post composer) only own-upload srcs survive; a pasted remote
// image still vanishes, mirroring the server-side drop in
// VutuvWeb.Markdown.render_post/2.
const imagePolicy = (allowImages) =>
  $prose(
    () =>
      new Plugin({
        key: new PluginKey("MDE_IMAGE_POLICY"),
        appendTransaction(transactions, _oldState, newState) {
          if (!transactions.some((tr) => tr.docChanged)) return null
          const ranges = []
          newState.doc.descendants((node, pos) => {
            if (node.type.name !== "image") return
            const ok = allowImages && OWN_IMAGE_SRC.test(node.attrs.src || "")
            if (!ok) ranges.push([pos, pos + node.nodeSize])
          })
          if (ranges.length === 0) return null
          const tr = newState.tr
          // Delete from the end so the earlier positions stay valid.
          ranges.reverse().forEach(([from, to]) => tr.delete(from, to))
          return tr
        },
      })
  )

// Watches the selection so the toolbar can reveal the alignment buttons while
// an image node is selected (and mark the active alignment on them).
const imageSelectionWatch = (hook) =>
  $prose(
    () =>
      new Plugin({
        key: new PluginKey("MDE_IMAGE_SELECT"),
        view: () => ({
          update: (view) => hook.syncImageSelection(view),
        }),
      })
  )

// Files dropped or pasted into the prose become uploads: remember where they
// should land, hand them to the form's LiveView file input and swallow the
// browser/ProseMirror default (which would navigate away or inline a data
// URI the server could never render).
const imageFileCapture = (hook) =>
  $prose(
    () =>
      new Plugin({
        key: new PluginKey("MDE_IMAGE_FILES"),
        props: {
          handleDOMEvents: {
            drop: (view, event) => {
              const files = imageFiles(event.dataTransfer)
              if (files.length === 0) return false
              const coords = view.posAtCoords({ left: event.clientX, top: event.clientY })
              hook.captureFiles(files, coords ? coords.pos : view.state.selection.head)
              event.preventDefault()
              return true
            },
            paste: (view, event) => {
              const files = imageFiles(event.clipboardData)
              if (files.length === 0) return false
              hook.captureFiles(files, view.state.selection.head)
              event.preventDefault()
              return true
            },
          },
        },
      })
  )

const imageFiles = (transfer) =>
  Array.from(transfer?.files || []).filter((f) => f.type.startsWith("image/"))

// Toolbar button (data-mde-cmd) -> Milkdown command. Each returns the command
// key + optional payload; `link` is special-cased (it needs a URL).
const COMMANDS = {
  strong: [toggleStrongCommand],
  em: [toggleEmphasisCommand],
  strike: [gfm.toggleStrikethroughCommand],
  code: [toggleInlineCodeCommand],
  bullet_list: [wrapInBulletListCommand],
  ordered_list: [wrapInOrderedListCommand],
  h1: [wrapInHeadingCommand, 1],
  h2: [wrapInHeadingCommand, 2],
  h3: [wrapInHeadingCommand, 3],
  blockquote: [wrapInBlockquoteCommand],
  code_block: [createCodeBlockCommand],
  table: [gfm.insertTableCommand],
  hr: [insertHrCommand],
}

export const MarkdownEditor = {
  async mounted() {
    this.root = this.el
    this.toolbar = this.el.querySelector("[data-mde-toolbar]")
    this.mountEl = this.el.querySelector("[data-mde-mount]")
    this.source = this.el.querySelector("[data-mde-source]")
    if (!this.mountEl || !this.source) return

    // The server-rendered Markdown is the seed and the "what does the server
    // currently hold" reference for updated() (image inserts, post-save resets).
    this.lastPushed = this.source.value
    this.syncing = false
    // View state lives in JS, not in DOM attributes: the root is server-managed,
    // so morphdom wipes any attribute we set on it at the next patch (every
    // keystroke re-renders the composer). applyState() re-stamps it in updated().
    this.mode = "wysiwyg"
    this.fullscreen = false
    this.imagesEnabled = this.root.dataset.mdeImages === "1"
    this.imageSelected = false
    // The height the member dragged the source textarea to, if they did. It is
    // the same story as the state above: `resize: vertical` makes the browser
    // write the drag onto the textarea's own inline `style`, and the textarea
    // is the server-rendered form field, so the patch after the next keystroke
    // or paste strips it and the box springs back (issue #1143). beforeUpdate()
    // reads it while it is still there, applyState() puts it back.
    this.sourceHeight = null
    // Files this editor sent to the upload input, waiting for the server's
    // `mde-image-uploaded` echo: [{name, pos}] — pos is where they were
    // dropped/pasted (null = current cursor at insert time).
    this.insertQueue = []

    const placeholderText = this.root.dataset.mdePlaceholder || ""

    let editor = Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, this.mountEl)
        ctx.set(defaultValueCtx, this.escapeFootnotes(this.source.value))
        ctx.get(listenerCtx).markdownUpdated((_ctx, markdown) => {
          if (this.syncing) return
          this.writeSource(this.normalizeMarkdown(markdown))
        })
      })
      .use(commonmark)
      .use(gfmSubset)
      .use(listener)
      .use(history)
      .use(placeholder(placeholderText))
      .use(imagePolicy(this.imagesEnabled))

    if (this.imagesEnabled) {
      editor = editor.use(imageSelectionWatch(this)).use(imageFileCapture(this))
      this.wireImageEvents()
    }

    this.editor = await editor.create()

    this.ensureTrailingParagraph()
    this.applyState()
    this.wireToolbar()
    this.wireSubmitShortcut()
  },

  // Last look at the DOM before morphdom patches it: a manual resize lives in
  // the textarea's inline style and the patch is about to drop it, so take a
  // copy. Never overwrite a remembered height with an empty one — an earlier
  // patch may already have stripped the style, and the member's choice should
  // outlive that.
  beforeUpdate() {
    if (!this.source) return
    if (this.source.style.height) this.sourceHeight = this.source.style.height
  },

  updated() {
    // morphdom just re-rendered the composer and stripped our JS-set attributes;
    // re-stamp them in the same synchronous patch (before paint, so no flicker).
    this.applyState()
    if (!this.editor) return
    // If the server changed the field out from under us (an inline image was
    // inserted, or the composer/message form reset after save), re-seed the
    // editor; skip the echo of our own last push so typing doesn't churn.
    const serverMd = this.root.dataset.mdeValue || ""
    if (serverMd === this.lastPushed) return
    this.lastPushed = serverMd
    this.source.value = serverMd

    if (this.mode !== "source") {
      this.setEditorMarkdown(serverMd)
      this.ensureTrailingParagraph()
    }
  },

  // Re-stamp the hook's view state onto the (server-managed) root. Cheap and
  // idempotent; safe to call on every patch.
  applyState() {
    this.root.dataset.mdeReady = "1"
    this.root.dataset.mdeMode = this.mode
    this.root.dataset.mdeFullscreen = this.fullscreen ? "1" : "0"
    this.root.dataset.mdeImg = this.imageSelected ? "1" : "0"
    if (this.sourceHeight) this.source.style.height = this.sourceHeight
  },

  destroyed() {
    this.editor?.destroy()
    // Drop the fullscreen Escape listener if we were destroyed mid-fullscreen
    // (e.g. navigated away with the editor open) — otherwise it survives on
    // `document` and its closure retains the whole editor.
    if (this._esc) document.removeEventListener("keydown", this._esc)
    document.body.classList.remove("mde-fullscreen-lock")
  },

  // --- helpers ---

  // Mirror the editor's Markdown into the hidden form field and fire `input`
  // so phx-change (validate / typing) runs, exactly as the plain textarea did.
  writeSource(markdown) {
    if (this.source.value === markdown) return
    this.source.value = markdown
    this.lastPushed = markdown
    this.source.dispatchEvent(new Event("input", { bubbles: true }))
  },

  editorMarkdown() {
    if (!this.editor) return this.source.value
    return this.normalizeMarkdown(this.editor.action(getMarkdown()))
  },

  // Milkdown emits a literal `<br />` for content it has no plain Markdown for:
  // an empty paragraph (a blank line the writer adds with Enter, a standalone
  // `<br />` block) and an empty table cell (`| <br /> |`). vutuv's renderer
  // escapes `<` on purpose (typed HTML shows as text), so those would render as
  // literal "<br />" text. Drop every `<br />` (empty paragraph collapses to a
  // break, empty cell stays empty) while leaving fenced code blocks verbatim so
  // a `<br>` in a code sample survives. Real hard breaks serialize as a trailing
  // backslash, not <br>. Only applied to the editor's own output, never to raw
  // text typed in source mode. Mirrors `strip_break_artifacts` in
  // VutuvWeb.Markdown, the rendering-side guard.
  normalizeMarkdown(md) {
    return this.mapOutsideFences(md, (part) =>
      this.canonicalizeFootnotes(this.canonicalizeMentions(this.canonicalizeUrls(part)))
        .replace(/<br\s*\/?>/gi, "")
        .replace(/\n{3,}/g, "\n\n")
    )
      .replace(/^\n+/, "")
      .replace(/\n+$/, "\n")
  },

  // Apply `fn` to the parts of a Markdown string that are not a fenced code
  // block, so a code sample keeps its exact characters. Mirrors
  // VutuvWeb.Markdown.split_code_regions/1 on the server.
  mapOutsideFences(md, fn) {
    return md
      .split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g)
      .map((part, i) => (i % 2 === 1 ? part : fn(part)))
      .join("")
  },

  // vutuv stores plain Markdown with **bare, unescaped** URLs — the server
  // autolinks them and shortens the display (see VutuvWeb.Markdown). But
  // Milkdown serializes a URL in the two forms remark produces, neither of which
  // vutuv can render:
  //
  //   * a recognized link whose text is the URL becomes an autolink
  //     `<https://ex.com>` — and vutuv escapes `<` at render time (typed HTML
  //     must show as text), so `<…>` never becomes a link; and
  //   * a bare URL sitting in plain text is escaped to stay literal —
  //     `https\://ex\.com/a\&b` — by mdast-util-gfm-autolink-literal's "unsafe"
  //     rules, so it will not re-parse as an autolink.
  //
  // Left as-is the stored source keeps the brackets/backslashes and the rendered
  // link breaks (a literal "<…>", or a stray ")" once a leftover backslash
  // confuses Earmark's link parser — issue #918). Canonicalize both back to the
  // bare form: drop the autolink brackets, then drop every backslash inside a
  // `scheme://…` run (a real URL never contains one, so each `\` is a Markdown
  // escape we undo). Runs on the non-fenced text only, so a URL shown verbatim
  // in a code block keeps its exact characters.
  canonicalizeUrls(md) {
    return md
      .replace(/<(https?:\/\/[^>\s]+)>/gi, "$1")
      .replace(/[a-z][a-z0-9+.-]*\\?:\/\/[^\s<>]*/gi, (url) =>
        url.replace(/\\(.)/g, "$1")
      )
  },

  // vutuv stores **bare** `@handle` / `#hashtag` mentions and links them
  // server-side (VutuvWeb.Markdown / Vutuv.Mentions read the raw source). But
  // Milkdown serializes a handle with an underscore escaped — `@ulrich_wolf` as
  // `@ulrich\_wolf`, `#foo_bar` as `#foo\_bar` — because `_` is a Markdown
  // emphasis char. On the source that stray backslash truncates the handle (the
  // mention-existence check reported "@ulrich does not exist"). Drop the escape
  // backslashes **inside a mention run only** so the stored handle is bare;
  // scoped to the run, an intended-literal `\_foo\_` in free prose keeps its
  // escapes and never turns into emphasis. Mirrors Vutuv.Mentions' source-side
  // un-escape and the RepairMilkdownEscapedMentions backfill.
  canonicalizeMentions(md) {
    return md.replace(
      /(?<![\w@#/&])([@#])((?:[A-Za-z0-9]|\\_)+)/g,
      (whole, sigil, handle) =>
        handle.includes("\\_") ? sigil + handle.replace(/\\_/g, "_") : whole
    )
  },

  // vutuv stores **bare** footnote syntax — `Satz[^1].` plus a `[^1]: note`
  // line — and renders it server-side (VutuvWeb.Markdown.Footnotes). The editor
  // has no footnote node: those stay ordinary text, which is exactly what a
  // member typing them expects to see. Two things do have to be papered over,
  // both from remark and both silent:
  //
  //   * `[` is escaped in phrasing content, so the editor would store `\[^1]`
  //     and the renderer would no longer recognize the footnote; and
  //   * a definition whose body is a bare URL — `[^1]: https://example.com`, the
  //     single most natural footnote there is — parses as a CommonMark LINK
  //     REFERENCE DEFINITION, a node the commonmark preset has no schema for,
  //     so re-opening such a post in the composer would drop the line entirely.
  //
  // Both are fixed by the same pair of mirrored transforms: escape `[^…]` on the
  // way IN (remark then sees an escaped bracket, never a link definition, and
  // renders the text as the plain `[^1]` the member typed), unescape it on the
  // way OUT. The backslash is never visible and never stored. Same shape as
  // canonicalizeUrls / canonicalizeMentions above, and the server tolerates the
  // escape too, as the guard for bodies stored before this existed.
  //
  // The one thing this gives up: a deliberately escaped, literal `\[^x]` comes
  // back unescaped. It changes nothing a reader sees — the server leaves a
  // reference with no definition as typed — so it would take writing the escape
  // AND a matching definition to notice, which is asking for a footnote anyway.
  // A code fence may name the file a snippet comes from and, for a diff, the
  // language inside it (issues #1137 and #1138) — either after a colon or as an
  // attribute:
  //
  //   ```php:config/app.php        ```php title="config/app.php"
  //   ```diff:php                  ```diff lang="php"
  //
  // Milkdown's code_block node has room for exactly ONE word (it stores the
  // info string's first word as `language` and serializes only that back), so
  // the attribute form would be silently destroyed the moment a post is
  // re-opened in the composer — the same shape of loss the footnote transforms
  // above exist to prevent. Fold it into the colon form on the way IN, which
  // Milkdown carries through untouched. The member sees their fence rewritten
  // to the short form once, and vutuv renders both.
  rewriteFenceInfo(md) {
    let open = null
    return md
      .split("\n")
      .map((line) => {
        const match = line.match(/^([ \t]{0,3})(`{3,}|~{3,})(.*)$/)
        if (!match) return line
        const [, indent, marker, info] = match
        if (open) {
          if (marker[0] === open.char && marker.length >= open.length && !info.trim()) open = null
          return line
        }
        open = { char: marker[0], length: marker.length }
        return indent + marker + this.fenceInfoWord(info)
      })
      .join("\n")
  },

  fenceInfoWord(info) {
    if (!/(?:^|\s)(?:title|lang)\s*=/i.test(info)) return info
    const attr = (key) =>
      (info.match(
        new RegExp(`(?:^|\\s)${key}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|(\\S+))`, "i")
      ) || []).slice(1).find((value) => value !== undefined)
    const word =
      info
        .replace(/(?:^|\s)(?:title|lang)\s*=\s*(?:"[^"]*"|'[^']*'|\S+)/gi, " ")
        .trim()
        .split(/\s+/)[0] || ""
    const language = word.split(":")[0]
    // A diff's colon segment is the language inside it, everything else's is
    // the file name — the same rule the server reads the short form by.
    const diff = /^(diff|patch|udiff)$/i.test(language)
    // A fence info string may hold no space, so a title that has one keeps it
    // as `%20` — which is exactly what the server decodes it back from.
    const rest = (diff ? attr("lang") : attr("title")) || ""
    return rest ? `${language}:${rest.replace(/\s/g, "%20")}` : word
  },

  escapeFootnotes(md) {
    return this.rewriteFenceInfo(
      this.mapOutsideFences(md, (part) =>
        part.replace(/(?<!\\)\[\^([^\]\s]{1,64})\]/g, "\\[^$1]")
      )
    )
  },

  canonicalizeFootnotes(md) {
    return md.replace(/\\(\[\^[^\]\s]{1,64}\])/g, "$1")
  },

  // ProseMirror offers no place to put the cursor after a trailing block that
  // owns its content: click below a blockquote, a table or a code block and the
  // cursor lands INSIDE it. That is fatal for a seeded quote (issue #1114) — the
  // whole document is one blockquote, so the answer would be typed into the
  // quotation. Append an empty paragraph so there is somewhere to write, and do
  // it after every seed rather than in a plugin: a plugin's appendTransaction
  // never sees the editor's initial state, which is exactly the state that needs
  // it. The paragraph costs nothing in the stored source — Milkdown serializes
  // it as the `<br />` artifact `normalizeMarkdown` already drops.
  ensureTrailingParagraph() {
    this.editor?.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const { state } = view
      const paragraph = state.schema.nodes.paragraph
      const last = state.doc.lastChild
      if (!paragraph || !last || last.type === paragraph) return
      view.dispatch(state.tr.insert(state.doc.content.size, paragraph.create()))
    })
  },

  setEditorMarkdown(markdown) {
    if (!this.editor) return
    this.syncing = true
    this.editor.action(replaceAll(this.escapeFootnotes(markdown || "")))
    this.syncing = false
  },

  focusEditor() {
    this.editor?.action((ctx) => ctx.get(editorViewCtx).focus())
  },

  run(name) {
    if (name === "mode") return this.toggleMode()
    if (name === "fullscreen") return this.toggleFullscreen()
    if (name === "toggle-toolbar") return this.toggleToolbar()
    if (name === "link") return this.runLink()
    if (name === "image") return this.pickImage()
    if (name.startsWith("img-")) return this.setImageAlignment(name.slice(4))
    const spec = COMMANDS[name]
    if (!spec || !this.editor) return
    const [command, payload] = spec
    this.editor.action(callCommand(command.key, payload))
    this.focusEditor()
  },

  // --- inline images (post composer only) ---

  // Server → hook events. `mde-image-uploaded` fires for every finished upload
  // (whoever initiated it); only files this editor forwarded — dropped, pasted
  // or toolbar-picked — sit in the insertQueue and get placed into the prose.
  // `mde-insert-image` is the thumbnail row's explicit "Insert into text".
  wireImageEvents() {
    this.handleEvent("mde-image-uploaded", (payload) => {
      if (payload.editor !== this.el.id) return
      const index = this.insertQueue.findIndex((entry) => entry.name === payload.name)
      if (index === -1) return
      const [entry] = this.insertQueue.splice(index, 1)
      this.insertImage(payload.url, payload.alt, entry.pos)
    })

    this.handleEvent("mde-insert-image", (payload) => {
      if (payload.editor !== this.el.id) return
      this.insertImage(payload.url, payload.alt, null)
    })

    // The 🖼 toolbar button clicks the form's (visually hidden) LiveView file
    // input. Its change event is how we learn which files were picked; the
    // listener is delegated to the form so it survives LiveView re-renders.
    this.source.form?.addEventListener("change", (e) => {
      if (!this.pendingPickInsert) return
      if (!(e.target instanceof HTMLInputElement) || e.target.type !== "file") return
      this.pendingPickInsert = false
      const pos = this.savedInsertPos
      for (const file of imageFiles(e.target)) {
        this.insertQueue.push({ name: file.name, pos })
      }
    })
  },

  fileInput() {
    return this.source.form?.querySelector('input[type="file"]')
  },

  pickImage() {
    const input = this.fileInput()
    if (!input) return
    this.pendingPickInsert = true
    this.savedInsertPos = this.editorSelectionHead()
    input.click()
  },

  // Dropped/pasted files: queue their names for insertion at `pos`, then hand
  // them to the LiveView file input (assigning `files` + firing input/change is
  // the programmatic path into `allow_upload`; the server answers each with an
  // `mde-image-uploaded` push event once processed).
  captureFiles(files, pos) {
    const input = this.fileInput()
    if (!input) return
    for (const file of files) this.insertQueue.push({ name: file.name, pos })
    const transfer = new DataTransfer()
    files.forEach((file) => transfer.items.add(file))
    input.files = transfer.files
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.dispatchEvent(new Event("change", { bubbles: true }))
  },

  editorSelectionHead() {
    if (!this.editor) return null
    let head = null
    this.editor.action((ctx) => {
      head = ctx.get(editorViewCtx).state.selection.head
    })
    return head
  },

  // Place an image node into the prose at `pos` (null = current cursor; the
  // position is clamped — the doc may have changed while the upload ran). In
  // source mode append the Markdown to the textarea instead.
  insertImage(url, alt, pos) {
    if (!this.editor || this.mode === "source") return this.insertImageSource(url, alt)

    this.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const { state } = view
      const type = state.schema.nodes.image
      if (!type) return
      const at = Math.min(pos ?? state.selection.head, state.doc.content.size)
      // TextSelection.near finds the closest valid text position (an inline
      // image can't sit between two block nodes).
      const selection = TextSelection.near(state.doc.resolve(at))
      const tr = state.tr.setSelection(selection)
      tr.replaceSelectionWith(type.create({ src: url, alt: alt || "" }), false)
      view.dispatch(tr)
      view.focus()
    })
  },

  insertImageSource(url, alt) {
    const md = `![${alt || ""}](${url})`
    const at = this.source.selectionStart ?? this.source.value.length
    const value = this.source.value
    this.source.value = `${value.slice(0, at)}${md}${value.slice(at)}`
    this.source.dispatchEvent(new Event("input", { bubbles: true }))
  },

  // Rewrite the selected image's alignment fragment ("full" clears it). The
  // fragment is the persisted form (part of the Markdown src); CSS previews it
  // in the editor and VutuvWeb.Markdown turns it into the modifier class.
  setImageAlignment(alignment) {
    if (!this.editor) return
    this.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const { state } = view
      const selection = state.selection
      if (!(selection instanceof NodeSelection) || selection.node.type.name !== "image") return
      const base = (selection.node.attrs.src || "").split("#")[0]
      const src = alignment === "full" ? base : `${base}#${alignment}`
      let tr = state.tr.setNodeMarkup(selection.from, undefined, {
        ...selection.node.attrs,
        src,
      })
      tr = tr.setSelection(NodeSelection.create(tr.doc, selection.from))
      view.dispatch(tr)
      view.focus()
    })
  },

  // Reveal the alignment buttons while an image is selected and mark the
  // active choice (aria-pressed drives the button styling).
  syncImageSelection(view) {
    const selection = view.state.selection
    const node =
      selection instanceof NodeSelection && selection.node.type.name === "image"
        ? selection.node
        : null
    this.imageSelected = node !== null
    this.root.dataset.mdeImg = this.imageSelected ? "1" : "0"
    const active = node ? (node.attrs.src || "").split("#")[1] || "full" : null
    for (const name of ["full", "left", "center", "right"]) {
      const btn = this.toolbar?.querySelector(`[data-mde-cmd="img-${name}"]`)
      if (btn) btn.setAttribute("aria-pressed", String(active === name))
    }
  },

  // Mobile: expand/collapse the extra toolbar groups. The class lives on the
  // toolbar (inside the phx-update="ignore" frame), so it survives re-renders
  // without needing applyState().
  toggleToolbar() {
    const open = !this.toolbar.classList.contains("is-open")
    this.toolbar.classList.toggle("is-open", open)
    const btn = this.toolbar.querySelector(".mde__more-toggle")
    if (btn) btn.setAttribute("aria-expanded", String(open))
  },

  runLink() {
    const href = window.prompt(this.root.dataset.mdeLinkPrompt || "Link URL")
    if (!href) return
    this.editor.action(callCommand(toggleLinkCommand.key, { href }))
    this.focusEditor()
  },

  wireToolbar() {
    if (!this.toolbar) return
    this.toolbar.addEventListener("mousedown", (e) => {
      // Keep the editor selection while clicking a toolbar button.
      if (e.target.closest("[data-mde-cmd]")) e.preventDefault()
    })
    this.toolbar.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-mde-cmd]")
      if (!btn) return
      e.preventDefault()
      this.run(btn.dataset.mdeCmd)
    })
  },

  // Cmd/Ctrl+Enter submits the surrounding form (the message composer wants it;
  // posts leave it off). Works from the WYSIWYG surface and the source textarea.
  wireSubmitShortcut() {
    if (this.root.dataset.mdeSubmit !== "cmd-enter") return
    const submit = (e) => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        this.source.form?.requestSubmit()
      }
    }
    this.mountEl.addEventListener("keydown", submit)
    this.source.addEventListener("keydown", submit)
  },

  toggleMode() {
    if (this.mode !== "source") {
      // Editor -> raw Markdown: hand the current Markdown to the textarea.
      this.source.value = this.editorMarkdown()
      this.mode = "source"
      this.applyState()
      this.source.focus()
    } else {
      // Raw Markdown -> editor: re-parse whatever the power user typed.
      this.setEditorMarkdown(this.source.value)
      this.writeSource(this.editorMarkdown())
      this.mode = "wysiwyg"
      this.applyState()
      this.focusEditor()
    }
  },

  toggleFullscreen() {
    this.fullscreen = !this.fullscreen
    this.applyState()
    document.body.classList.toggle("mde-fullscreen-lock", this.fullscreen)
    if (this.fullscreen) {
      this._esc = (e) => {
        if (e.key === "Escape") this.toggleFullscreen()
      }
      document.addEventListener("keydown", this._esc)
    } else if (this._esc) {
      document.removeEventListener("keydown", this._esc)
      this._esc = null
    }
    this.mode === "source" ? this.source.focus() : this.focusEditor()
  },
}
