# Direct messages

Persisted 1:1 conversations (`Vutuv.Chat`) at `/messages`, with live delivery,
typing indicators and online dots.

Anyone validated can write to anyone, but the conversation lands directly only
when the **recipient already follows the sender** — otherwise it is a **message
request** the recipient accepts (explicitly or by replying) or declines;
declining is silent (the sender cannot tell it from being ignored) and opening
new requests is rate-limited — the **cold-outreach cap** (`config :vutuv,
:cold_outreach`, `COLD_OUTREACH_LIMIT` / `COLD_OUTREACH_WINDOW_HOURS`, default
20 / 24h): the anti-spam ceiling on new requests to strangers, over which the
sender gets a friendly "try again later". `Chat.cold_outreach_count/1` exposes
the current spend to admins (issue #934; the `/admin/jobs` poster footprint).

The shell badge counts conversations with unread messages, and a debounced email
quotes the message and points the recipient back at the thread.

The composer is the shared **Milkdown WYSIWYG Markdown editor**
(`VutuvWeb.UI.markdown_editor/1`, its compact variant — the same one the post
composer uses); Cmd/Ctrl+Enter sends. Messages are stored and rendered as
Markdown (`VutuvWeb.Markdown.render/1`), unchanged by the editor. The `typing`
handler keeps the draft body in the form so the editor clears after a send; see
`.claude/rules/design.md` for the component. Emoji come with it (issue #1197):
the 🙂 toolbar button's picker and the `:tada:` type-through both work here, and
both store the emoji **character**, so a message needs no rendering change.

Because the stored body is Markdown **source**, every place that shows a message
outside the thread must flatten it or it prints the markers themselves. The
one-line glance form is `VutuvWeb.Markdown.to_preview_line/1` (plain text, block
breaks folded into spaces, capped at 200 chars): the sidebar's last-message line
and the `preview` field of the API's conversation list both go through it. In
the LiveView that happens once per entry where the lists are built
(`put_preview/1` in `MessageLive.Index`, on the `Chat` query result and on the
in-memory bump), never in the template — the sidebar rows re-render on every
presence tick and typing event, which would re-parse every preview each time.

The **unread-message email** quotes the DM in full rather than at a glance, so it
uses the email renderer (`VutuvWeb.EmailMarkdown`, the one invitations use: full
Markdown, bare URLs kept whole and clickable, images dropped) — the HTML body
through `<.email_markdown>`, the `text/plain` body through
`EmailMarkdown.to_text/1`, which flattens that same HTML and expands each link to
`label (url)`, because in a text body nothing is clickable and the URL *is* the
link. Quoting the raw source instead put "Hello \*\*[Stefan](https://…" in the
member's inbox.

Messages carry **no images**: `Vutuv.MarkdownContent.validate_no_images/2` in
`Message.changeset` rejects a body with image Markdown (`![](…)`) on every write
path (the web composer and `POST …/messages` alike — a 422 for the API), and
`VutuvWeb.Markdown.render/1` drops any `<img>` at display time, so a legacy body
never shows one. The Milkdown editor also strips image nodes client-side, so a
pasted picture never survives (`assets/js/markdown_editor.js` — the message
composer does not set the editor's `images` option). **Posts differ**: a post
body may embed the post's own uploaded attachments inline
([posts-and-feed.md](posts-and-feed.md)); messages have no uploads, so their
bodies stay image-free.

Each member controls this on the notifications settings page: whether they are
emailed about **every** unread message or only the **first** of a burst (the
default), and how long a message may sit unread before the email goes out (0 to
120 minutes, default 15); every such email says which mode is active and
deep-links to those settings.

## Writing to a page (issue #1336)

A conversation can have a **page** on the other side. `conversations` grew a
nullable `organization_id` beside `user_b_id` with a CHECK that exactly one of
them is set, so there are two shapes:

    member <-> member: user_a_id + user_b_id (sorted), organization_id NULL
    member <-> page:   user_a_id = the member, user_b_id NULL, organization set

`user_a_id` is always the member. The sorted pair was **not** generalised:
sorting exists to break the symmetry between two ids from the same table, and
these two come from different ones, so the pair is already canonical and a
second unique index is the whole story.

**There is no second messages page.** A publisher who switched into a page
(`acting_as`, issue #1335) opens the same `/messages` and finds the *page's*
inbox; everybody else finds their own. `MessageLive.Index` resolves one
`:viewer` assign at mount — `acting_as || current_user` — and every `Chat` call
on the page goes through it. That identity is re-derived from the roles on every
mount, so a withdrawn publisher lands on their own inbox rather than the page's.

What differs on the page's side, and why:

  * **No request/accept dance.** A page publishes in order to be addressed, so
    there is nothing for it to approve, and a "pending" state would make its
    team's first reply look like an acceptance.
  * **One participant row for the whole team**, not one per publisher: read
    means somebody read it, never that everybody did — the model
    `organizations.activity_read_at` already sets. A row per publisher would
    also have to be minted and retired as roles change.
  * **A reply is the page's**, with `messages.acting_user_id` recording who
    typed it and never showing it — the same split `posts` makes for authorship,
    so the message does not walk out of the door with the person.
  * **No block, no online dot.** Both are about people.
  * **The right to answer follows the role**, asked live on every send.

### The nullable column charged its usual toll

Everything above is cheap. The readers were not. `conversations.user_b_id`
became nullable, and a member's own list matches on `user_a_id`, so a page
conversation turned up in it immediately — where `other_user/2` resolved a nil
id and `Repo.one!` **raised**. Three more places tested `sender_id != <id>`,
which is NULL and not true for a page's message, so its reply counted as unread
nowhere and its notification mail never went out. `Chat.other_party/2` and
`Chat.own_message/1` are the two functions that now own those questions; a call
site naming either column directly is the bug to look for.
