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
handler keeps the draft body in the form so a reconnect can recover it; what
empties the composer after a send is the **re-seed token** `assign_form/1` bumps
beside the reset body (`seed=`), because the editor deliberately ignores its own
text coming back — every other re-render on this page, the other side's typing
bubble included, must leave the writer's caret alone. See
`.claude/rules/design.md` for the component — including that there is no
toolbar since issue #1886: marks come from the selection bubble, blocks from
the slash menu, and the `Text | Markdown` switch sits under the field. Emoji
come with it (issue #1197) as the `:tada:` type-through, which stores the emoji
**character**, so a message needs no rendering change.

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

## Files and pictures (issue #2110)

Between two **connected** members a message also carries files and pictures —
the same formats and limits as a post, plus the photo formats. The rule, why
the gate is asked three times, what ending the connection does, and how a
picture differs from a post photo are written up in
[attachments.md](attachments.md); what belongs here is the shape it takes on
this page. `Vutuv.Chat.files_allowed?/1` is the one function that decides, and
a page's inbox answers false.

The composer grows a picker beside Send and a chip strip **above** the editor,
inside the always-rendered `#attachment-slot` — same reason as `#typing-slot`
and `#request-slot`: an `:if` on a direct child would relocate the form and
throw the Milkdown caret out mid-word. The chips carry hidden
`message[attachment_ids][]` inputs so a reconnect recovers them, and
`adopt_recovered_attachments/2` re-adopts through `Attachments.pending_for/2`,
which re-checks the owner and both parents.

A message may have an **empty body** when it carries files, which is what
sending a picture with no caption produces; `Message.changeset/3` takes
`files?: true` and stores `""` (the column is NOT NULL). The sidebar's
one-line preview then says how many files instead of nothing, and that count
costs a second query only for the conversations whose newest message really is
blank.

A file settling — rendered, past the AI check, refused — broadcasts
`{:message_attachment, message_id}` on the conversation topic
(`Vutuv.Attachments.announce/1`), so both bubbles redraw without a reload: the
sender's state and, once it has passed, the recipient's file.

Messages carry **no images** in the body: `Vutuv.MarkdownContent.validate_no_images/2` in
`Message.changeset` rejects a body with image Markdown (`![](…)`) on every write
path (the web composer and `POST …/messages` alike — a 422 for the API), and
`VutuvWeb.Markdown.render/1` drops any `<img>` at display time, so a legacy body
never shows one. The Milkdown editor also strips image nodes client-side, so a
pasted picture never survives (`assets/js/markdown_editor.js` — the message
composer does not set the editor's `images` option). **Posts differ**: a post
body may embed the post's own uploaded attachments inline
([posts-and-feed.md](posts-and-feed.md)). A message's pictures hang **beside**
the text as attachments (above), never inside it, so the body stays image-free
whatever the message carries.

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

## Writing to another network

A conversation can also have an **account on another network** on the other
side, so a member writes to somebody on Mastodon the way they write to a member
here: from that account's page, in `/messages`, in the same thread.

    member <-> member: user_a_id + user_b_id (sorted)
    member <-> page:   user_a_id + organization_id
    member <-> remote: user_a_id + remote_account_id

`user_a_id` is always the member, a CHECK says the other side is exactly one of
the three, and the remote side has **no participant row**: nobody over there
has a read state here, and inventing one would be a promise nothing keeps.

**`initiator_id` became nullable, and NULL means the remote side started it.**
That is what makes the member the recipient of a request they can accept or
decline. Every rule reading "the initiator is not me" then has to spell it as
`is_nil(...) or ... != me`, because in SQL `NULL != <id>` is NULL and not true —
the same trap the page milestone paid for twice, and it caught three queries
here: `answer_request/3`, `list_requests/1` and the shell's own
`unread_conversations_count/1`. That last one also tested `m.sender_id <> <id>`,
NULL for a message written by a page **or** by a remote account, so the badge
had been quietly ignoring a page's replies since #1336 as well.

### One truth, two views

A private answer from another network is a `fediverse_notes` row under the
member's post and keeps rendering there exactly as before (#1069, #1071,
#2215). What is new is the **second view**: the same words as a message in the
conversation with that account, linked by `messages.note_id` (a sent answer by
`messages.private_message_id`). Both links are `ON DELETE SET NULL`, so when the
note ages out after 183 days the conversation keeps the text and only loses the
way back to the post. The two views point at each other — the card carries "Open
in messages", the message "To the post" — and `Vutuv.Chat.messages_for_notes/1`
resolves that for a whole page of cards in one query
(`Fediverse.conversation_refs/1`, onto the note's virtual `conversation_ref`).

An author's edit upstream (`Update`) rewrites both copies; nothing else may
write either one.

### What arrives, and from whom

`Fediverse.record_reply/3` tries the post path first, exactly as before, and
falls through to `record_direct_message/3` for a `Create` addressed to the
member alone that answers none of their posts — which the server used to drop
on the floor. Three notes on the gates:

  * It is **not** behind `users.fediverse_replies?`. That switch is about
    strangers' words appearing under a member's posts, in public; a message
    addressed to one person is their mail, and `federated?/1` (participation,
    opt-in and off by default) already decides whether this member exists out
    there at all.
  * An account the member does not follow opens a **pending** conversation, the
    request wall `Vutuv.Chat` already gives cold outreach between members.
    Following that account is what makes the conversation accepted outright.
  * A redelivery writes nothing twice: `messages.remote_object_uri` is unique
    and asked before the insert.

Outgoing, `Fediverse.send_direct_message/3` writes three rows in one
transaction — the `PrivateMessage` (what left the building), the `Delivery` (the
queue entry a crash or a deploy resumes) and the `Chat.Message` — addressed to
that one actor with no public collection and no followers, threaded under the
last thing the other side said so clients there show one conversation. It shares
the hourly outbound budget with public replies.

### Starting one, and finding the way back

Every other conversation here starts from somebody's page. An account nobody
on this installation has ever heard of has no page, so `/messages` carries a
**New message to another network** box: an address in, that account's
conversation out. Resolving costs an outbound request and a slot of the
member's hourly budget, so it is a submit they make on purpose — a native
`<details>` (`data-keep-open`, or a ticking badge folds it shut over a
half-typed address) around the shared `<.address_form>`, whose `change` event
this page has to name for itself because `typing` already means the typing
indicator here. Without Fediverse participation the box explains where the
switch is instead of taking an address it could not send.

The two views link to each other **by anchor**, not merely to each other's
page: `Fediverse.reply_anchor/1` for a note and `private_reply_anchor/1` for a
sent answer, each owned in one place and rendered as the `id` of the box under
the post. A conversation that has run a while hangs under a post with a whole
thread under it, and a link that only opened that page left the reader hunting
for the message they pressed.

### What this conversation has that a local one does not

One line at the top of the thread, said once rather than under every bubble:
only this account receives these messages, and like emails they are not
end-to-end encrypted. No file button (text only, 5,000 characters), no block
item (blocking is about people here), no online dot. And the composer stays open
after the first message: there is no acceptance to wait for on a server that
knows nothing about requests, so the "not accepted yet" line a member would have
been left staring at is never shown there.

### Reporting, and what is deliberately missing

A message from another network carries **no report flag**. `Moderation`'s
report path strikes the member who wrote the thing, and here there is none, so
the flag would be a control that always fails. The complaint has three real
answers instead: the note's own report under the post
(`Fediverse.report_note/2`, which deletes our copy and files a `Flag` with the
origin server), muting the account, and the operator's server block. A message
that answers no post — a plain DM — has only the last two; if that turns out to
matter, the missing piece is a `Flag` path that does not hang off a note.

### Housekeeping

`purge_unreferenced_remote_accounts/0` treats a conversation as a fifth reason
to keep an account row — without that, the hourly sweeper would take a member's
correspondence with it. `messages.sender_remote_account_id` is nilified rather
than cascaded, so an operator blocking a server does not delete what was said.

The exchanges that existed before this were given their conversations by
`20260920074019_backfill_fediverse_conversations`, whose `run/1` is driven
directly by a test: a data migration's row-touching branches never execute
against a fresh test database, which is how a backfill ships broken.
