# Account activity log

The append-only record of what changed on an account, when, from where and how
it was confirmed (issue #1087). It exists for one sentence support hears all the
time: *"I didn't do anything!"* — and for the member who wants to check that for
themselves without writing in at all.

Before it, security-relevant changes left no durable trace. The signed-in
devices list (`user_sessions`) shows *sessions*, and `username_changes` counts
renames for the quota, but nothing recorded that a username was renamed, an
email address added or the search-engine switch flipped, let alone when or from
where.

## The row

`Vutuv.AccountEvents.AccountEvent`, one table, no `updated_at`, no update
changeset:

| Column | Holds |
|---|---|
| `user_id` | whose account this is about (cascades with the account) |
| `actor_user_id` | who did it, **only** when that was somebody else (an admin) |
| `kind` | what happened, from a closed vocabulary |
| `factor` | how it was confirmed: `passkey` / `authenticator` / `list_code` / `pin` / `session` / `admin` |
| `device` | the **coarse** summary (`"Chrome on macOS"`), never the raw User-Agent |
| `details` | a small per-kind map, key-whitelisted |
| `inserted_at` | UTC, **microsecond** precision |

The precision is deliberate. Support has to be able to say "you changed this at
14:32:07", and two changes inside the same second must still have an order —
which second-resolution timestamps (what the rest of the app stores) cannot give.

**There is no IP address.** The first cut kept one; it is gone. For the member
the question is "was that me?", and the device summary, the exact time and the
confirming factor answer it — while a year of IP addresses per account is a
movement profile nobody asked us to keep, sitting in a table an admin page and
every backup can read. (`user_sessions` still stores one per signed-in device:
that is the devices list and the new-device security email, a different feature
with its own lifetime.) Removing it took two releases, per the N-1 migration
rule: v7.159.1 stopped writing and reading the column and nulled what was
already there, v7.159.2 dropped it.

## What may never be in it

Not the value of anything secret or guessable-and-private. No PIN, token,
passkey material, TOTP secret or one-time list code — those never reach the
module. No muted word (a filter row records its *kind*, never the pattern), no
message, no postal address, no IP address. **Email addresses are stored masked**
(`AccountEvents.mask_email/1`: `an***@example.com`), enough for the owner to
recognize which of their addresses it was and not enough for a leaked backup or
an admin screen to harvest one.

Settings saves record the **names** of the fields that were submitted, never
their values: which switches a member touched is what answers "when did my
profile stop being indexed?", while the values are on the page itself.

That rule is structural rather than a matter of discipline. `@kinds` in
`Vutuv.AccountEvents` is the whole vocabulary and each kind declares exactly
which `details` keys it may carry; `AccountEvent.changeset/2` rejects an
undeclared kind or key outright. Adding a fact to the log means adding it there
first, where "is this safe to keep for a year?" is unavoidable.
`test/vutuv/account_events_test.exs` fails the build if a declared key ever
reads like a credential.

## Writing

`Vutuv.AccountEvents.record/3` is the one write path and is **best-effort**: a
log write must never break the action it records, so a failure is logged and
swallowed. Call it from the chokepoint that already exists, not from every call
site.

The hooks, by area:

- **Sessions** — `Vutuv.Accounts.login/3` (`signed_in`, with the factor the
  member proved it with) and `logout/1` (`signed_out`); the two device controls
  on `/settings/security` (`session_revoked`, `other_sessions_revoked`).
- **Factors** — passkey add/remove, the authenticator app on/off, a fresh or
  deleted one-time code list.
- **Identity** — the rename's one commit path in
  `VutuvWeb.UsernameController` (`username_changed`, both handles, the
  confirming factor), the email add/remove/visibility actions, the profile
  basics save.
- **Privacy and reach** — the visibility, notification and Fediverse settings
  saves; blocking and unblocking (recorded at the `Vutuv.Social` chokepoint, so
  it covers the /blocks form, the profile menu and the report flow alike);
  adding and removing a content filter; the automatic-post-deletion rule
  (`auto_post_deletion_changed`) and each pass that it took posts in
  (`posts_auto_deleted`, one line per Berlin day carrying the count and nothing
  else — **which** posts they were is precisely what is gone, and naming them
  would rebuild a list of deleted posts inside a log that outlives them by a
  year).
- **Data** — the GDPR download, an applied LinkedIn import.
- **Apps** — an access token minted or revoked, a connected app disconnected.
- **Somebody else acting** — an admin freeze/unfreeze, a restore, an identity
  verification, a support preference override, a force-rename. These land in the
  **member's** log with `actor_user_id` set, which is what turns a baffled "my
  name changed by itself" into an answerable question.

Where a new factor is proved, the factor travels with it:
`Vutuv.LoginCodes.redeem_login_code/2` answers `{:ok, :authenticator}` /
`{:ok, :list_code}`, and `Accounts.check_login_code/2` /
`check_confirmation_code/3` return `{:ok, user, factor}`.

## Reading

Two readers, one query builder.

**The member** — `/settings/activity` (`VutuvWeb.AccountActivityLive`), in the
Account group of the settings menu. Newest first, one row per event reading as a
sentence with a to-the-second `<.local_time precision="second">` stamp, the
device it came from, how it was confirmed, and an amber "Not by you"
marker when `actor_user_id` is set. Search over device / factor / details,
a kind filter offering only the kinds that actually occur, sorting by time (both
ways) and by kind, numbered paging. **Every row ends in a quiet "Not you?" link
into `/settings/security`** — a log you cannot act on is a curiosity, not a
safeguard. The security page carries the last five events as a card, which is
how the page is discovered at all: somebody who suspects something goes there,
not to a page whose name they have never seen.

**Support** — `/admin/activity` (`VutuvWeb.Admin.ActivityLive`), the same rows
across every member, plus a member filter (name, @handle or email address) and a
sortable Member column; a handle in a row is itself a filter.

**Reading somebody else's activity is itself recorded.** The admin page files an
`activity_log_viewed` event on the **admin's own** account: once when the page
is opened, and once more per distinct member filter that actually returns rows —
the moment a particular member's activity was really put on screen. It goes on
the admin's log rather than the member's on purpose: it is the admin's action,
it belongs in the trail of what that admin did, and it is answerable to whoever
reviews the admins.

Filter, sort and page live in the URL on both pages (`push_patch`), so a
particular view is shareable and the back button restores it.

## Retention

The log is personal data — devices, what changed when — so it ages out. `Vutuv.AccountEvents.Sweeper` deletes rows past
`AccountEvents.retention_days/0` daily; the default is **365 days**, settable per
installation via `ACCOUNT_EVENT_RETENTION_DAYS`. A year covers the "this
happened months ago and I only noticed now" support case without turning the
table into a permanent movement profile.

It rides along in the GDPR export (`Vutuv.Export`, schema version 5) and
cascades away with the account. When an *admin* account is deleted, the member's
row survives with `actor_user_id` nilled: the member's own history must not
disappear because a colleague left.
