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

`deliver/1` also stamps the bounce envelope sender: the `Sender` header (the
`BOUNCE_ADDRESS` variable, `bounces@vutuv.de` on vutuv.de) becomes the SMTP MAIL
FROM.

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
a tokenized footer link (`/unsubscribe/:token`, no login needed); transactional
mail (PINs, moderation) cannot be opted out of.

## Bounces and deliverability

**Bounces feed back** (`Vutuv.Deliverability`): the production log watcher tails
Postfix's `mail.log` (the `/webhooks/bounces` DSN endpoint feeds the same path)
and marks a hard-bounced address undeliverable, `deliver/1` then drops automatic
mail to it; PIN mail still sends, and a successful login PIN through the address
clears the mark. A confirmed account whose **every** address is dead is frozen
as unreachable (hidden from others, owner and admins still see it); admins track
and undo all of it at `/admin/deliverability`. Full design in
[`docs/production-email-and-bounces.md`](../production-email-and-bounces.md)
