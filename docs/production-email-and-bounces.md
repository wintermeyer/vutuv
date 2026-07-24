# Production email delivery & bounce handling

**TL;DR** — vutuv sends all outbound mail through a **shared Postfix relay on the
production host** (`bremen2`), with the SMTP envelope sender fixed to
`sw@vutuv.de` (the `BOUNCE_ADDRESS` variable; see §1.6). When a recipient
address dies, the goal is to (1) **stop
mailing it** and (2) eventually **freeze accounts that have become permanently
unreachable**. The signal for "this address is dead" comes from Postfix's own
delivery log (`/var/log/mail.log`), which records every send result. This file
documents the production mail topology, how a bounce is detected and acted on,
the decisions behind that design, and a runbook to reproduce the whole setup on
a new server. It exists because the bounce path depends on host-specific mail
configuration that is invisible from the application code and would otherwise be
lost on a server migration.

Related code: `Vutuv.Notifications.Emailer` (the send chokepoint),
`Vutuv.Notifications.Bounces` (records a bounce, marks the address
undeliverable), `VutuvWeb.WebhookController` (`POST /webhooks/bounces`),
`Vutuv.Accounts.Email` (`undeliverable_at`). Related issue: **#760** (publish
SPF / DKIM / DMARC for vutuv.de).

---

## 1. Production mail topology (as of 2026-06-20)

The production app runs on **`bremen2.wintermeyer.de`** (IP `134.102.58.61`, also
reachable as `wort.fb12.uni-bremen.de` on the Uni-Bremen network), Debian 13
(trixie), **Postfix 3.10.5**. The OS user / install path / systemd units use
`vutuv3`; the OTP release is `vutuv`.

### 1.1 The send path

```
  Vutuv app (Swoosh, SMTP adapter)
        │  MAIL FROM:<sw@vutuv.de>        (the Sender header; see Emailer.deliver/1)
        │  submitted to 127.0.0.1:25, no TLS (loopback)
        ▼
  Postfix on bremen2  ──────────────►  recipient's MX (direct, relayhost is empty)
   (shared by several apps)              e.g. gmail-smtp-in.l.google.com
        │                                     aspmx.l.google.com (for @vutuv.de inbound, see below)
        │  logs every attempt to
        ▼
  /var/log/mail.log   ──►  "status=sent | deferred | bounced", with dsn=code + the
                            remote server's reply.  THIS is our bounce signal.
```

Key Postfix settings on bremen2 (read with `postconf`):

| Setting | Value | Why it matters |
|---|---|---|
| `relayhost` | *(empty)* | Postfix delivers straight to each recipient's MX. |
| `inet_interfaces` | `all` | Listens for submission; apps connect on `127.0.0.1:25`. |
| `mynetworks` | loopback only | Only processes on the box may relay outbound. |
| `mydestination` | `…, animina.de, bremen2.wintermeyer.de, wort.fb12.uni-bremen.de, localhost` | Domains delivered **locally**. **`vutuv.de` is NOT here.** |
| `transport_maps` | *(empty)* | No per-address routing override. |

### 1.2 It is a **multi-tenant** relay

bremen2 sends outbound mail for **several unrelated apps**, distinguishable only
by their envelope sender. Seen in the logs:

- `sw@vutuv.de` — **vutuv** (us); `bounces@vutuv.de` before 2026-07-22, so
  older log excerpts in this document still show that address
- `…@animina.de` — animina
- `noreply@mehr-schulferien.de` — mehr-schulferien

**Consequence:** a `status=bounced` log line does **not** by itself belong to
vutuv. Any bounce-detection MUST attribute the message to vutuv first (join the
queue-id back to a `from=<BOUNCE_ADDRESS>` line — see §3.2). Acting on a raw
`status=bounced` would deactivate addresses for other apps' bounces. The
attribution address is read from config, so changing `BOUNCE_ADDRESS` moves it
in lockstep — but a message already queued under the *old* address bounces
under that old envelope and is no longer recognized as ours. That window is the
Postfix queue lifetime (minutes for most mail, up to ~5 days for deferred), and
it costs only detection, never a wrong deactivation.

### 1.3 `vutuv.de` inbound mail lives on **Google Workspace**

```
$ dig +short MX vutuv.de
1  aspmx.l.google.com.
5  alt1.aspmx.l.google.com.        ← inbound @vutuv.de mail goes to Google, NOT bremen2
...
```

So `info@vutuv.de`, `sw@vutuv.de`, etc. are **received by Google**, not by
bremen2. bremen2 only *sends* as `sw@vutuv.de`; it is not the destination
for that address. This single fact rules out the "read the bounce mailbox"
design — see §2.

### 1.4 vutuv.de is SPF-authorized from this host (good)

```
$ dig +short TXT vutuv.de
"v=spf1 mx a ip4:134.102.58.61 -all"
```

bremen2's IP is explicitly authorized to send for vutuv.de (`-all` hard-fails
everyone else). So **vutuv's own outbound mail passes SPF** and is unlikely to
be rejected for authentication reasons. The many `5.7.26 … unauthenticated /
DMARC` bounces in the shared log are **other tenants** (animina.de,
mehr-schulferien.de) whose domains do *not* authorize `134.102.58.61` — not
vutuv. DKIM/DMARC for vutuv.de are still open work (**#760**); until they exist,
the detector must still treat policy bounces (`5.7.x`) as "not the recipient's
fault" (§3.3) so a future DKIM gap can never be misread as dead mailboxes.

### 1.5 Log access

`/var/log/mail.log` is `root:adm`, mode `640`, rotated by logrotate
(`mail.log`, `mail.log.1`, `mail.log.2.gz`, …). The app user **`vutuv3` is not
in the `adm` group**, so the app cannot read the log as-is. Two ways to grant
the detector access — see §3.5.

### 1.6 The envelope sender must be a mailbox that really accepts mail

`BOUNCE_ADDRESS` is where every DSN is addressed, so an address that does not
exist throws the returned bounces away. vutuv.de sent as `bounces@vutuv.de`
from the start, but that account was **never created** in Google Workspace, and
Google rejects unknown recipients at RCPT time:

```
$ printf 'EHLO bremen2.wintermeyer.de\r\nMAIL FROM:<>\r\nRCPT TO:<bounces@vutuv.de>\r\nQUIT\r\n' \
    | openssl s_client -quiet -starttls smtp -connect aspmx.l.google.com:25
550-5.1.1 The email account that you tried to reach does not exist.
```

Automated bounce handling never depended on it (that reads the log, §2), but it
meant no DSN, and no remote postmaster's reply to it, ever reached a human. On
**2026-07-22** production switched to `sw@vutuv.de` — a real mailbox, `250 OK`
on the same probe — set as `BOUNCE_ADDRESS` in `/var/www/vutuv3/shared/.env`.
Run that probe for whatever address you configure before trusting it; the
shipped default in `config/config.exs` is unchanged and is *not* a working
mailbox.

---

## 2. Why bounce detection reads the log (and not a bounce mailbox)

There are two ways to learn that an address bounced. The application code
(`Bounces.record/1` + `POST /webhooks/bounces`) was originally written for
**Option A**, but **Option B is what actually fits this server**, and it is a
superset.

### Option A — DSN to a local bounce mailbox → pipe → webhook (NOT used here)

The classic design: outbound mail uses the envelope sender as a bounce mailbox;
when delivery fails, the *remote* server (or Postfix itself, on giving up)
returns a **DSN** (delivery status notification) addressed to that sender;
Postfix delivers it into a **local** mailbox piped into
`scripts/postfix/vutuv-bounce`, which POSTs the raw DSN to `/webhooks/bounces`.

**Why it does not work on bremen2 as configured:** the bounce address resolves
via the **vutuv.de MX → Google** (§1.3), and `vutuv.de` is not in
`mydestination`. So a DSN addressed to it is sent **out to
Google**, never to a local pipe. Making Option A work would require **either**:

- a Postfix `transport_maps` override that forces *just* the bounce address to
  local delivery (keeps Google MX for `info@vutuv.de` etc.), **or**
- repointing the whole vutuv.de **MX** at bremen2 — which would drag **all**
  inbound `@vutuv.de` mail off Google Workspace. That is a far bigger change than
  the problem warrants and is **not recommended** (see §5).

Either way it only catches what becomes a DSN, and gives no early signal on
repeated *soft* failures (needed for the freeze decision, §4.2) until Postfix
finally expires the message (~5 days).

> **Security caveat: a raw mailbox pipe trusts forged DSNs (issue #1063).**
> Where Option A *is* wired, `scripts/postfix/vutuv-bounce` forwards whatever
> lands in the bounce mailbox to `/webhooks/bounces` verbatim, and the webhook
> acts on the DSN's `Final-Recipient` / `Status` with no check that this
> installation ever mailed that address. `BOUNCE_WEBHOOK_TOKEN` only proves the
> message came through the pipe, not that the bounce is genuine. Because that
> mailbox accepts arbitrary inbound internet mail, anyone can send a forged DSN
> for an address they know and have it marked undeliverable; enough repeats (or
> the grace window) then freeze the account and hide the profile (§4). Option B
> does not have this hole: the log watcher only ever acts on a bounce it can
> join back to *our own* outbound queue-id (§3.2), which is exactly the
> sender/recipient correlation the webhook lacks. Prefer Option B, and do not
> wire the raw mailbox pipe until the webhook grows that correlation (#1063).

### Option B — read Postfix's delivery log (CHOSEN, implemented)

`Vutuv.Deliverability.Watcher` (a GenServer) tails `/var/log/mail.log`,
`Vutuv.Deliverability.MailLog` attributes and classifies each line, and a
confirmed hard bounce is handed to `Vutuv.Deliverability.record_hard_bounce/3` —
the same path the DSN webhook (`Vutuv.Notifications.Bounces.record/1`) now also
funnels through, so the address-deactivation machinery (`EmailBounce`,
`undeliverable_at`) is shared, not duplicated.

Why this is the better fit here:

- **No mail-routing surgery.** Zero Postfix config changes, no MX change, no
  transport override. Works the same on any Postfix host.
- **The signal is already there**, reliably, today (hundreds of real lines in the
  rotated logs).
- **Superset of information.** It sees `sent` / `deferred` / `bounced` with the
  full SMTP reply and `dsn=` code immediately — exactly the data the freeze
  permanence-scoring (§4.2) needs, which a DSN-only path lacks.
- **Reuses the existing webhook + token**, so Layer 1 (§4.1) needs no new app
  endpoint.

The only added cost is attribution (§3.2) and log read access (§3.5), both
small.

---

## 3. Reading the bounce signal

### 3.1 Anatomy of a delivery-result line

```
<ts> bremen2 postfix/smtp[PID]: <QUEUEID>: to=<user@example.com>,
   relay=mx.example.com[1.2.3.4]:25, delay=…, dsn=5.1.2,
   status=bounced (host mx.example.com said: 550 5.1.2 No such mailbox …)
```

- `status=` is `sent` (delivered), `bounced` (permanent give-up), or `deferred`
  (transient, will retry).
- `dsn=` is the RFC 3463 enhanced status code; its **class** is what matters
  (§3.3).
- `to=<…>` is the recipient. `<QUEUEID>` ties the line to the rest of that
  message's lifecycle.

### 3.2 Attributing a bounce to vutuv (the queue-id join)

The bounce line carries `to=` but **not** the envelope sender. To know a bounce
is vutuv's, join its `<QUEUEID>` to the `qmgr` line for the same id:

```
postfix/qmgr[PID]: <QUEUEID>: from=<sw@vutuv.de>, size=…, nrcpt=1 (queue active)
postfix/smtp[PID]:  <QUEUEID>: to=<user@…>, …, dsn=5.1.2, status=bounced (…)
```

Same `<QUEUEID>` + `from=<sw@vutuv.de>` ⇒ vutuv's mail ⇒ act on it.
Anything else (animina, mehr-schulferien, system cron mail) is ignored.

> Implementation note: the queue-id sits as `…postfix/xxx[pid]: <QUEUEID>: …`
> — i.e. after `]: `, not `] `. A naive `] <id>` extraction matches nothing.

### 3.3 What each DSN class means for us

| dsn / status | Example seen in prod | Meaning | Action |
|---|---|---|---|
| `5.1.1` `5.1.2` `5.1.3` `5.5.0` + `bounced` | "No such mailbox", "User unknown", "mailbox unavailable", "not a valid RFC 5321 address" | **Recipient is dead.** | Deactivate the address (§4.1); count toward freeze (§4.2). |
| `5.0.0` + `bounced`, text confirms a dead recipient | "550 Requested action not taken: mailbox unavailable", "552 … mailbox not found" | **Recipient is dead** (bare 550/552 reply, no enhanced code). | Same as above — but only with confirming text. |
| `5.0.0` + `bounced`, quota or block text | "552 … exceeded storage allocation … Quota exceeded", "550 … (user@host:blocked)" | **Mailbox is full, or the recipient's filter blocked this message.** The mailbox lives. | **Do NOT deactivate.** Quota → ignore; block → treated like a policy bounce. |
| `5.7.x` + `bounced` | `5.7.26 … unauthenticated … DMARC` | **Sender/policy problem, not the recipient.** (Our SPF/DKIM, or the remote's policy.) | **Do NOT deactivate.** Alert ops instead — this means *our* sending is broken for a whole class of recipients. |
| `4.x.x` + `deferred` | `4.0.0 … receiving mail too quickly`, mailbox full | **Transient.** Postfix keeps retrying. | Never deactivate. Only repeated/aging deferrals feed freeze scoring (§4.2). |

Treating `5.7.x` as a dead recipient is the most dangerous false positive: a
single DKIM misconfiguration would otherwise "kill" every Gmail recipient at
once. Deactivation gates on the `5.1.x / 5.5.x` recipient families — and on
`5.0.x` **only when the reply text itself confirms a dead recipient**
(`Vutuv.Deliverability.MailLog`). `5.0.0` is not an enhanced code from the
remote: Postfix maps any bare `550`/`552` reply to it, so the bucket mixes
dead mailboxes with full mailboxes and recipient-side spam/IP blocks. The
July 2026 newsletters proved the hazard: 19 members with full (gmx/web.de
quota) or filter-blocked mailboxes were deactivated and then frozen; the
`RepairMisclassifiedBounceFreezes` migration thawed them and the classifier
has vetted `5.0.x` by text ever since.

### 3.4 Where the alarms land (journal visibility)

Production runs the global Logger at `:error` (`config/prod.exs`) to keep the
journal quiet — which would swallow every deliverability log line: the
watcher's policy-bounce warning, its startup line, the webhook's bounce
lines, the emailer's dropped-mail warnings. Since v7.122.5,
`Vutuv.Application` raises exactly these modules to `:info` at boot via
`Logger.put_module_level/2` (flag `:ops_log_visibility`, on by default), so
they reach the journal while everything else stays at `:error`:

```
journalctl -u 'vutuv3@blue' -u 'vutuv3@green' | grep -E 'Deliverability|Email bounce|Dropped|Suppressed'
```

The startup line `Deliverability.Watcher tailing /var/log/mail.log …` doubles
as the liveness check that the watcher is running in the current release.

### 3.5 Granting the detector log access (pick one)

- **Add `vutuv3` to the `adm` group** (`usermod -aG adm vutuv3`, then restart the
  release) and let the app tail the log directly. Simplest; reversible.
- **A tiny root-side shipper** (systemd unit) that tails the log and POSTs
  vutuv-attributed bounces to `POST /webhooks/bounces` with `BOUNCE_WEBHOOK_TOKEN`.
  Keeps the app unprivileged; reuses the existing endpoint verbatim. The
  "vutuv-attributed" is load-bearing: the shipper must do the queue-id join
  itself (§3.2) and forward *only* bounces for our own outbound mail. Forwarding
  a raw bounce *mailbox* into the webhook instead (Option A, §2) reopens the
  forged-DSN hole (#1063), because the webhook does no correlation of its own.

---

## 4. What the app does with a confirmed bounce

Two layers, split by risk. The address-level action is safe and reversible; the
account-level action is gated hard because bounces lie (§3.3).

### 4.1 Layer 1 — deactivate the dead address (safe, reversible, already coded)

A hard bounce sets `emails.undeliverable_at`
(`Vutuv.Deliverability.record_hard_bounce/3`). Then:

- `Emailer.deliver/1` **drops automatic mail** to that address.
- **PIN / login mail is exempt** (`put_private(:user_initiated, true)`): a
  once-bounced mailbox must never lock its owner out.
- A **successful login PIN clears the mark** (`Accounts.check_pin/3` →
  `Bounces.clear/1`): proof the address works again.
- The owner sees a "mail to this address bounced" warning on their emails page.

### 4.2 Layer 2 — freeze genuinely unreachable accounts (implemented)

`Vutuv.Deliverability.reassess_user/1` freezes an account **only** when it is
truly unreachable: a **confirmed** account whose **every** address has bounced
(login works via any address, so one dead address is not enough), and only after
**repeated** hard bounces (`@min_hard_bounces`) or once an address has been dead
past a grace period (`@grace_days`, swept daily by `Vutuv.Deliverability.Sweeper`)
— never on a single bounce. Such an account can never receive a PIN again, so it
is a zombie.

The freeze is a **dedicated state**, `users.unreachable_at`, not the moderation
`frozen_at` (which means "in the abuse-review freezer"). It hides the profile
from other members (`Vutuv.Moderation.account_hidden?` reads it) but stays
visible to the owner and admins. It un-freezes automatically when a login PIN
proves an address works again (`Vutuv.Accounts.check_pin/3` re-assesses), or when
an admin thaws it. The PIN screen also carries a generic, always-shown hint
pointing a member whose inbox died at another of their addresses (no enumeration
leak).

Every transition is written to the `deliverability_events` ledger, and the admin
dashboard at **`/admin/deliverability`** lists frozen accounts, deactivated
addresses, the bounce ledger and the audit trail, with one-click **thaw** and
**clear** undo actions.

---

## 5. Why we do **not** change the MX

Repointing vutuv.de's MX at bremen2 would route **all** inbound `@vutuv.de` mail
(info@, real human mail, everything) to bremen2 and **off Google Workspace** —
breaking existing mailboxes for the sake of one robot bounce address. The
bounce-detection design (§2, Option B) needs **no** DNS change at all. If Option
A were ever wanted, the correct tool is a **local `transport_maps` override for
just the bounce address** (no MX change). Only consider an MX change if there is
a separate, deliberate decision to **self-host all of vutuv.de's inbound mail** —
a much larger project, unrelated to bounce handling.

---

## 6. Runbook — reproduce on a new production server

1. **DNS**: keep vutuv.de's MX on its mail host (Google). Ensure the new sending
   host's IP is in vutuv.de's **SPF** (`ip4:<new-ip>`); add **DKIM** + **DMARC**
   (#760) so outbound passes authentication and is not 5.7.26-rejected.
2. **Postfix** on the new host: a plain relay is enough — apps submit on
   `127.0.0.1:25`, `relayhost` empty (direct-to-MX) or a smarthost. No special
   config is required for bounce handling under Option B.
3. **App env**: set `BOUNCE_WEBHOOK_TOKEN` in the release env file
   (`/var/www/vutuv3/shared/.env`, mode 600, owner `vutuv3`). Without it
   `/webhooks/bounces` 404s and bounce handling is simply off (fail-closed).
4. **Log access**: give the detector read access to `/var/log/mail.log`
   (§3.5) — add the app user to `adm`, or install the root-side shipper.
5. **Verify** end to end (§7): send to a known-bad address, watch the log line,
   confirm `undeliverable_at` gets set, then clear it with a real PIN login.

> The whole bounce path depends on items 1–4, none of which live in the app
> repo's runtime config. Re-do them deliberately on any migration.

---

## 7. How to test it live (production)

```sh
# 1. From the app, send any automatic mail to an address you control that is
#    guaranteed to bounce (e.g. a nonexistent mailbox on a domain you own).
# 2. Watch Postfix hand it off and the remote reject it:
ssh root@<host> "tail -f /var/log/mail.log | grep --line-buffered status="
#    → look for: from=<sw@vutuv.de> … to=<dead@…> … dsn=5.1.1, status=bounced
# 3. Confirm the address was marked (in a remote IEx / release eval):
#    Vutuv.Notifications.Bounces.suppressed?("dead@example.com")  # => true
# 4. Clear it the real way: log in with a PIN through a WORKING address and
#    confirm the mark is gone (Accounts.check_pin → Bounces.clear).
```

The Swoosh **test** adapter never renders or sends real mail, so bounce handling
**cannot** be covered by `mix test` alone — it must be smoke-tested against a
real Postfix as above.

---

## 8. Current status (2026-06-20)

- **Live in production** (v7.1.0): `Vutuv.Deliverability` + `MailLog` + `Watcher`
  + `Sweeper`, the admin dashboard, the PIN-screen hint. Both signal sources (log
  watcher and DSN webhook) funnel through one path.
- **Switched on on bremen2.** `vutuv3` was added to the `adm` group and the
  release restarted, so the watcher reads `/var/log/mail.log` (`MAIL_LOG_PATH`
  defaults to it). Verified end to end: a real `550 5.1.1` bounce was recorded in
  the `email_bounces` ledger within ~1s (§7). The watcher starts at end-of-file,
  so a restart never re-actions the historical log. `BOUNCE_WEBHOOK_TOKEN` / the
  DSN pipe are unused (the log path was chosen instead).
- **#760** (SPF/DKIM/DMARC for vutuv.de) is the prerequisite that keeps our own
  mail out of the `5.7.x` bucket.

