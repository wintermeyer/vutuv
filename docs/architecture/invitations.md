# Invitations

Any logged-in member can invite someone who is not yet on this vutuv. They fill
in what would be that person's sign-up (gender, name, tags, email address), an
optional personal note and the invitation's language, and choose whether to
auto-follow the person once they register. vutuv emails a link that opens the
sign-up form already filled in, so the invited person only has to confirm.

The form lives at **`/system/invitations/new`** (login-required, `noindex`;
linked from the account dropdown as "Invite a friend"), and `POST
/system/invitations` records + sends. Both are `VutuvWeb.InvitationController`;
all the logic is in the **`Vutuv.Invitations`** context.

## What is stored

`Vutuv.Invitations.Invitation` (`invitations` table) is a write-once record with
**no plaintext address**:

| column | meaning |
|---|---|
| `user_id` | the inviter |
| `email_hash` | SHA-256 of the normalized (trimmed + downcased) address — the only trace of who was invited |
| `locale` | `en` / `de`, the language the inviter chose |
| `auto_follow` | whether the inviter follows the newcomer on registration |
| `visited_at` | when the invited person first opened the link (nullable) |
| `inserted_at` | via `timestamps()` |

The personalized note is **not** stored — it only ever goes into the one email.
`VutuvWeb.InvitationController` binds an embedded `InvitationRequest` schema for
the form (all the sign-up fields + note + auto-follow + language); it validates
that `email` plus at least one of `first_name` / `last_name` are present.

## The three guarantees

- **Invite each address at most once, site-wide.** A `unique_index` on
  `email_hash` enforces it. A repeat (even by a different member) inserts
  nothing, sends nothing, and returns `{:ok, :already_invited}` — the controller
  shows the **same** neutral confirmation as a first send ("If this is the first
  invitation to that address, we are sending it by email right now."), so the
  sender can never learn that the address had been invited before.
- **A per-inviter daily cap** (`Vutuv.Invitations.daily_cap/0`, default 50,
  configurable — see below) protects the installation's sender reputation. The
  count is per member per Europe/Berlin calendar day.
- **Privacy.** Only the hash is stored, so a database leak cannot reveal who was
  invited.

## The link and the sign-up prefill

The email's call-to-action is `https://<host>/?i=<token>` (the host comes from
`PHX_HOST` via `Endpoint`'s `public_url`, never a literal domain). The `i` token
is a **compact, URL-safe packing** of the prefill fields — the values in a fixed
order, DEFLATE-compressed and base64url-encoded by
`Vutuv.Invitations.PrefillToken`. It replaces the old spelled-out
`?first_name=…&last_name=…&gender=…&tags=…&email=…` query, which repeated the
parameter names on every link, percent-encoded the values (`@` → `%40`) and
exposed the invitee's name and address in cleartext in mail logs and browser
history. For a real invite (which always has a name — the form requires it) the
token is ~30 % shorter and leaks no PII. Note that compression pays off only
*after* packing: DEFLATE-ing the spelled-out query on its own makes it longer
(header + base64 overhead beat the win on such short text), so the saving is
really from dropping the repeated keys, with DEFLATE trimming a further bit on
longer payloads. The token is **unsigned** on purpose — the fields are only form
defaults the invited person edits before submitting, and a signature would add
~50 characters and undo the saving. `PrefillToken.query/1` even picks the shorter
of the token and the spelled-out form, so a link is never made longer.

`VutuvWeb.PageController.index` reads the prefill with
`Vutuv.Invitations.prefill_from_params/1` (which decodes the `i=` token, or falls
back to the spelled-out params — older invitation links still in inboxes — when
there is none; a malformed token degrades to an empty form) and prefills the
sign-up changeset. The consent checkboxes are deliberately **left to the invited
person** — prefilling a consent choice would be wrong. The same request stamps
`visited_at` once (`Vutuv.Invitations.record_visit/1`, scoped to
`is_nil(visited_at)`), so a later visit never moves it.

## Auto-follow on registration

When someone registers, `PageController.new_registration` calls
`Vutuv.Invitations.apply_auto_follow/2`, which hashes the registered address,
finds the invitation, and — if it asked for auto-follow — makes the inviter
follow the new member (`Vutuv.Social.follow/2`). A no-op when the address was
never invited, the flag was off, or the inviter is gone.

## Email

The invitation is built by `Vutuv.Notifications.Emailer.invitation_email/1` and
sent through the single `Emailer.deliver/1` chokepoint like every other message.
It renders the `invitation_en` / `invitation_de` HTML + text templates in the
inviter's chosen language, quoting the personal note only when present. It is
**not** flagged user-initiated, so bounce suppression still applies (a
previously-undeliverable address is not mailed again).

## Configuration

`config :vutuv, :invitation_daily_cap` (default `50`) — the per-member daily cap.
Env-overridable per installation via `INVITATION_DAILY_CAP` (see
[ADMINS.md](../ADMINS.md)). The feature needs no host assumptions and makes no
outbound network calls beyond the mail it already sends, so it works unchanged
on any installation.
