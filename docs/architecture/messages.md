# Direct messages

Persisted 1:1 conversations (`Vutuv.Chat`) at `/messages`, with live delivery,
typing indicators and online dots.

Anyone validated can write to anyone, but the conversation lands directly only
when the **recipient already follows the sender** — otherwise it is a **message
request** the recipient accepts (explicitly or by replying) or declines;
declining is silent (the sender cannot tell it from being ignored) and opening
new requests is rate-limited.

The shell badge counts conversations with unread messages, and a debounced email
quotes the message and points the recipient back at the thread.

The composer is the shared **Milkdown WYSIWYG Markdown editor**
(`VutuvWeb.UI.markdown_editor/1`, its compact variant — the same one the post
composer uses); Cmd/Ctrl+Enter sends. Messages are stored and rendered as
Markdown (`VutuvWeb.Markdown.render/1`), unchanged by the editor. The `typing`
handler keeps the draft body in the form so the editor clears after a send; see
`.claude/rules/design.md` for the component.

Messages carry **no images**: `Vutuv.MarkdownContent.validate_no_images/2` in
`Message.changeset` rejects a body with image Markdown (`![](…)`) on every write
path (the web composer and `POST …/messages` alike — a 422 for the API), and
`VutuvWeb.Markdown.render/1` drops any `<img>` at display time, so a legacy body
never shows one. The Milkdown editor also strips image nodes client-side, so a
pasted picture never survives (`assets/js/markdown_editor.js`). Posts share the
same rule (`Vutuv.Posts.Post` + [posts-and-feed.md](posts-and-feed.md)); their
uploaded pictures are attachments shown as a gallery, messages have none.

Each member controls this on the notifications settings page: whether they are
emailed about **every** unread message or only the **first** of a burst (the
default), and how long a message may sit unread before the email goes out (0 to
120 minutes, default 15); every such email says which mode is active and
deep-links to those settings.
