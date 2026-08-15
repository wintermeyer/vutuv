# Email

vutuv sends all email with Swoosh over SMTP (operator-facing configuration:
[ADMINS.md](../ADMINS.md)). In development every email lands in the mailbox
preview at `/sent_emails`.

## One chokepoint

Every vutuv email is machine-generated, so all of it carries the
`Auto-Submitted: auto-generated` (RFC 3834) and `X-Auto-Response-Suppress: All`
headers to keep out-of-office and other auto-responders silent. Mail is built
from `Vutuv.Notifications.Emailer.base_email/0` and sent through the single
`Emailer.deliver/1` chokepoint, the only place allowed to call
`Vutuv.Mailer.deliver/1`.

## Envelope, headers and replies

`deliver/1` also stamps the bounce envelope sender (`BOUNCE_ADDRESS`,
`bounces@vutuv.de` on vutuv.de). It is the RFC 5321 **SMTP envelope sender**
(`MAIL FROM`) and travels beside the message, never as a visible `Sender:`
header: a `Sender:` is shown to the reader, and Outlook renders one as
"`bounces@vutuv.de` on behalf of vutuv `<no-reply@vutuv.de>`" — a mail-handling
address presented as the party that wrote the message (issue #1472).

Swoosh's own SMTP adapter has no seam for that (`Helpers.sender/1` is
`headers["Sender"] || from`), so production sends through
**`Vutuv.Mailer.SMTP`**, which is that adapter with the envelope sender passed
to the SMTP conversation directly. `Vutuv.Mailer.SMTPTest` proves both halves
against a real throwaway SMTP server, because neither is visible in a
`%Swoosh.Email{}`.

The bounce address doubles as the marker that tells vutuv's own mail apart from
the other tenants' in the shared Postfix log, so it must be a mailbox that
really accepts mail — see `docs/production-email-and-bounces.md` §1.6.

**Replies.** The From is not read, so mail is deliberately non-replyable unless
it says otherwise. The two messages whose copy invites a reply — the strike-3
deactivation and the AI image rejection, both appeals against an automated
decision — carry a `Reply-To` to the configured `APPEAL_REPLY_TO` contact, so
an appeal reaches a human. Nothing else sets one.

## Mail classes

Every builder declares one class (`Emailer.put_class/2`) and the chokepoint
derives the handling from it. `Vutuv.Notifications.MailClassTest` lists every
builder, so a new one fails the build until somebody decides its class.

| Class | Bounce suppression | Unsubscribe | `Precedence: bulk` |
|---|---|---|---|
| `:critical` (login PINs, the new-sign-in warning, ad bookings) | exempt | never | never |
| `:transactional` (their own account, page, content; operator notices) | applies | never | never |
| `:notification` (activity news) | applies | required | never |
| `:bulk` (newsletter, saved-search digest) | applies | required | yes |

`:critical` is not a synonym for "important": it is the exemption from vutuv's
*own* undeliverable mark. The way back into an account (a PIN) and the warning
that somebody else is in it must not be withheld by a mark this installation
set itself, possibly wrongly. The registration-attempt notice deliberately
stays `:transactional` even though it is security mail, because a *third party*
triggers it by typing somebody else's address into the sign-up form.

## Multipart bodies

Every email goes out as **multipart** (`text/plain` + `text/html`). The text
body lives in the per-locale `*.text.eex` templates
(`lib/vutuv_web/templates/email/`); the HTML alternative lives in the matching
`*.html.heex` bodies (`lib/vutuv_web/templates/email_body/`), composed from one
shared, inline-styled framework (`VutuvWeb.EmailComponents`: a brand-wordmark
layout, dark mode, and blocks like the PIN box, CTA button and key/value panel).
The two formats are paired by a drift test, so an email added with only one
fails the build.

## Opt-out and unsubscribe

**Notification mail is opt-out**: the unread-message nudge respects
`users.notification_emails?`, carries RFC 8058 one-click unsubscribe headers and
a tokenized footer link (`/unsubscribe/:token`, no login needed); critical and
transactional mail (PINs, security warnings, moderation) cannot be opted out of.
The class table above is where that line is drawn and tested.

## Bounces and deliverability

**Bounces feed back** (`Vutuv.Deliverability`): the production log watcher tails
Postfix's `mail.log` (the `/webhooks/bounces` DSN endpoint feeds the same path)
and marks a hard-bounced address undeliverable, `deliver/1` then drops automatic
mail to it; PIN mail still sends, and a successful login PIN through the address
clears the mark. A confirmed account whose **every** address is dead is frozen
as unreachable (hidden from others, owner and admins still see it); admins track
and undo all of it at `/admin/deliverability`. Full design in
[`docs/production-email-and-bounces.md`](../production-email-and-bounces.md)
