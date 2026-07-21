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
// wrapInTaskListInputRule) and footnotes, which the server doesn't render.
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
    // Files this editor sent to the upload input, waiting for the server's
    // `mde-image-uploaded` echo: [{name, pos}] — pos is where they were
    // dropped/pasted (null = current cursor at insert time).
    this.insertQueue = []

    const placeholderText = this.root.dataset.mdePlaceholder || ""

    let editor = Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, this.mountEl)
        ctx.set(defaultValueCtx, this.source.value)
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

    this.applyState()
    this.wireToolbar()
    this.wireSubmitShortcut()
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
    if (this.mode !== "source") this.setEditorMarkdown(serverMd)
  },

  // Re-stamp the hook's view state onto the (server-managed) root. Cheap and
  // idempotent; safe to call on every patch.
  applyState() {
    this.root.dataset.mdeReady = "1"
    this.root.dataset.mdeMode = this.mode
    this.root.dataset.mdeFullscreen = this.fullscreen ? "1" : "0"
    this.root.dataset.mdeImg = this.imageSelected ? "1" : "0"
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
    return md
      .split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g)
      .map((part, i) =>
        i % 2 === 1
          ? part
          : this.canonicalizeMentions(this.canonicalizeUrls(part))
              .replace(/<br\s*\/?>/gi, "")
              .replace(/\n{3,}/g, "\n\n")
      )
      .join("")
      .replace(/^\n+/, "")
      .replace(/\n+$/, "\n")
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

  setEditorMarkdown(markdown) {
    if (!this.editor) return
    this.syncing = true
    this.editor.action(replaceAll(markdown || ""))
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
