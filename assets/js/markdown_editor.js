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
// Images are excluded too: post bodies never embed pictures inline (uploaded
// images are shown as a gallery, not in the prose), and VutuvWeb.Markdown drops
// every `![](…)` at render time. commonmark bundles an image node, so a pasted
// picture or a typed `![alt](src)` would otherwise create one; the stripImages
// plugin below removes any image node so the editor stays honest to what renders.
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
import { Plugin, PluginKey } from "@milkdown/kit/prose/state"
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

// Keep the editor image-free: strip any image node the schema might create from
// a pasted picture or a typed `![alt](src)`. Mirrors the server-side drop in
// VutuvWeb.Markdown.render_post/2, so the WYSIWYG never shows an image that the
// rendered post would silently omit.
const stripImages = $prose(
  () =>
    new Plugin({
      key: new PluginKey("MDE_NO_IMAGES"),
      appendTransaction(transactions, _oldState, newState) {
        if (!transactions.some((tr) => tr.docChanged)) return null
        const ranges = []
        newState.doc.descendants((node, pos) => {
          if (node.type.name === "image") ranges.push([pos, pos + node.nodeSize])
        })
        if (ranges.length === 0) return null
        const tr = newState.tr
        // Delete from the end so the earlier positions stay valid.
        ranges.reverse().forEach(([from, to]) => tr.delete(from, to))
        return tr
      },
    })
)

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

    const placeholderText = this.root.dataset.mdePlaceholder || ""

    this.editor = await Editor.make()
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
      .use(stripImages)
      .create()

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
          : this.repairEscapedUrls(part)
              .replace(/<br\s*\/?>/gi, "")
              .replace(/\n{3,}/g, "\n\n")
      )
      .join("")
      .replace(/^\n+/, "")
      .replace(/\n+$/, "\n")
  },

  // Milkdown can serialize a plain URL as `https\://…\&…`; vutuv stores plain
  // Markdown, and the server autolinker expects a real `https://` URL.
  repairEscapedUrls(md) {
    return md.replace(/(?<![\w/])https?\\:\/\/[^\s<>]+/g, (url) =>
      url.replace(/\\([:&])/g, "$1")
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
    const spec = COMMANDS[name]
    if (!spec || !this.editor) return
    const [command, payload] = spec
    this.editor.action(callCommand(command.key, payload))
    this.focusEditor()
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
