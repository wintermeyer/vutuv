# Running your own vutuv

vutuv is free, open-source software (MIT license): any organization or person can
run their own installation — on the public internet or inside an intranet.
This document is the operator's manual: how to install, configure, and run it.

**We would love to hear about your installation!** If you run vutuv somewhere,
tell us about it — and report anything that made installing harder than it
should be — via a [GitHub issue](https://github.com/wintermeyer/vutuv/issues/new).

Related documents: [README](../README.md) (overview) ·
[DEVELOPERS](DEVELOPERS.md) (codebase, architecture, dev setup) ·
[CONTRIBUTING](../CONTRIBUTING.md).

## What you need

- A Linux server (the reference installation runs Debian; anything that runs
  Erlang works). One host is enough to start (vutuv.de has run on a single
  machine so far); very large installations can spread across multiple nodes,
  which Elixir/BEAM supports natively.
- **PostgreSQL 17** (older 14+ versions likely work, 17 is what is tested).
- **git** — the build reads the commit it is made from: the application version
  is that commit's date and the footer links the commit. A source archive
  without `.git` still builds, but reports version `0.0.0` and names no commit.
- **Erlang and Elixir** to build the release — install via
  [mise](https://mise.jdx.dev/) (`mise install` reads the pinned versions from
  `.tool-versions`).
- **libvips** for image processing (`apt-get install libvips-dev`).
- **Chromium** (optional) — only for URL screenshots and moderation evidence
  screenshots. Without it those features quietly do nothing.
- **poppler-utils** (optional, `apt-get install poppler-utils`) — renders the
  first page of PDF proof documents that members can attach to their
  certificates & licenses. Without `pdftoppm` on `$PATH`, PDF uploads are
  refused with a clear message ("please upload an image instead"); image
  proofs keep working.
- An **SMTP relay** vutuv can send email through. Email is not optional:
  login works via emailed PINs (vutuv is passwordless).
- **nginx** (or another reverse proxy) in front of the app. Optional for a
  first test, recommended for real use.

No Node.js is required (esbuild and Tailwind are Elixir deps), and there are
no external runtime services beyond PostgreSQL and SMTP.

## Build a release

```bash
git clone https://github.com/wintermeyer/vutuv.git
cd vutuv
mise install
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The self-contained release lands in `_build/prod/rel/vutuv/` — copy it to
where you want to run it (it must be built on the same OS/architecture).

## Database

Create a database and a user for it, e.g.:

```sql
CREATE USER vutuv WITH PASSWORD '...';
CREATE DATABASE vutuv3_prod OWNER vutuv;
```

Migrations run from the release (also used for every later upgrade):

```bash
bin/vutuv eval "Vutuv.Release.migrate()"
```

## Configuration

All runtime configuration comes from environment variables, read at boot by
`config/runtime.exs`. The recommended setup is a `chmod 600` EnvironmentFile
loaded by systemd (see below).

Two variables are **required** — the release refuses to boot without them:

| Variable | Purpose |
|---|---|
| `DB_PASS` | PostgreSQL password |
| `SECRET_KEY_BASE` | session/cookie signing — generate with `mix phx.gen.secret` |

Everything else has a default (the vutuv.de production value):

| Variable | Default | Purpose |
|---|---|---|
| `PHX_HOST` | `vutuv.de` | **Set this.** The public host name; every generated URL uses it |
| `PHX_SCHEME` | `https` | `http` for a TLS-less intranet installation |
| `PHX_URL_PORT` | `443`/`80` | The public port, if not the scheme default |
| `PORT` | `4003` | Local port the app listens on (loopback; nginx proxies to it) |
| `CHECK_ORIGINS` | – | Extra allowed websocket origins, comma-separated (host + `www.` twin are always allowed) |
| `LOG_LEVEL` | `error` | How much the release writes to the system log. The default is deliberately quiet — only failures, and nothing per request. Set `info` for a boot while you are chasing a problem (that adds the request log: one line per request with path, status and duration), `debug` to see every database query as well, and put it back afterwards: `info` on a busy installation is a lot of disk. A handful of modules are exempt in the other direction: the deliverability alarms and the AI image scan log at `info` whatever you set here, because an operator has to be able to read them (`Vutuv.Application.ops_log_modules/0`). That is why a journal can carry `[info]` and `[warning]` lines while this says `error` — the node names those modules once per boot, `grep logger_override`. An unrecognised value is ignored rather than refused, so a typo cannot stop a boot |
| `DB_USER` | `vutuv` | PostgreSQL user |
| `DB_NAME` | `vutuv3_prod` | PostgreSQL database |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host |
| `POOL_SIZE` | `10` | DB connection pool |
| `UPLOADS_DIR_PREFIX` | `/srv/legacy-vutuv` (fallback only) | **Set this.** Root directory for uploaded images (avatars, covers, screenshots, post images, private originals). The default is a historical fallback, not a recommendation: pick a directory your app user owns (vutuv.de uses `/srv/vutuv3`) |
| `CHROMIUM_PATH` | – | Chromium binary, if not on `$PATH` |
| `SCREENSHOT_BLOCKLIST` | – | Extra pages never to take a link-preview screenshot of, on top of the shipped `reddit.com` and `heise.de`. Comma-separated domains and/or URLs, copied into the blocklist table the first time you migrate; afterwards the live list is edited in the admin area (see "Screenshot blocklist" below) and this variable is inert. `SCREENSHOT_BLOCKED_HOSTS` is the older name and still works |
| `SMTP_RELAY` | `127.0.0.1` | SMTP server |
| `SMTP_PORT` | `25` | SMTP port |
| `SMTP_USERNAME` | – | SMTP auth (empty = no auth) |
| `SMTP_PASSWORD` | – | SMTP auth |
| `SMTP_TLS` | `never` | STARTTLS: `never` / `if_available` / `always` |
| `SMTP_SSL` | `false` | `true` for implicit TLS (usually port 465) |
| `NEWSLETTER_SEND_TIMEOUT_SECONDS` | `60` | Wall-clock ceiling on a single newsletter send. gen_smtp's per-response read timeout is a fixed 20 minutes, so a black-holing relay could otherwise freeze a broadcast long enough to look stuck and be double-sent; a timed-out send is logged as an error and the loop moves on. Raise it only for a legitimately slow smarthost, and keep it well under five minutes |
| `MAILER_FROM_NAME` | `vutuv` | Display name of the From on every email |
| `MAILER_FROM_ADDRESS` | `no-reply@vutuv.de` | **Set this.** From address on every email |
| `BOUNCE_ADDRESS` | `bounces@vutuv.de` | **Set this**, to a mailbox on your own domain that really accepts mail — bounces (DSNs) are addressed to it. It is the SMTP envelope sender only and never appears as a header, so it needs no display name and no human reading it; an alias or an automated handler is enough. Do not use a person's address: it is not shown to recipients, but it is what a remote postmaster replies to |
| `OPERATOR_NAME` | `Wintermeyer Consulting` | **Set this.** Your name: site/email footer credit and operator-notice recipient name |
| `OPERATOR_EMAIL` | `sw@wintermeyer-consulting.de` | **Set this.** Receives the daily report, ad bookings and account-deletion records; also the `security.txt` contact |
| `OPERATOR_URL` | `https://wintermeyer-consulting.de` | **Set this.** Linked from the site/email footer |
| `OPERATOR_ADDRESS` | (vutuv.de's) | **Set this.** One-line postal address in every email footer |
| `SOURCE_URL` | `https://github.com/wintermeyer/vutuv` | Where the source of the software you run can be read — the footer's "Source" link and the commit link beside it, the bug-report links on the error pages and in the developer docs, and the `source_url` / `repository` fields both API discovery documents publish. **Change this if you run a modified vutuv:** the link claims to be the source of what your users are running, so once you have patched anything, ours is no longer an honest answer. vutuv is MIT, so this is about accuracy rather than a licence obligation |
| `OPERATOR_HANDLE` | `wintermeyer` | The @handle of the person your media kit (`/system/media-kit`) names as the press contact; their profile is linked there for the remaining contact details. The link appears only when the handle really belongs to a member of *your* installation, so leaving the default set costs you nothing but a missing link. `""` renders none at all |
| `APPEAL_REPLY_TO` | (vutuv.de's) | Reply-To on the account-deactivation (strike 3) email |
| `BOUNCE_WEBHOOK_TOKEN` | – | Bearer token for `POST /webhooks/bounces`; unset = the endpoint 404s and webhook bounce handling is off. **Prefer the log watcher (`MAIL_LOG_PATH`) to this webhook:** the webhook acts on the DSN it receives without verifying the installation ever mailed the address, so feeding it a raw local bounce mailbox lets a forged bounce freeze a member ([#1063](https://github.com/wintermeyer/vutuv/issues/1063)). On a watcher-only setup leave this unset |
| `MAIL_LOG_PATH` | `/var/log/mail.log` | Postfix log the bounce watcher tails; `""` = watcher off |
| `POST_EDIT_WINDOW_MINUTES` | `30` | How long a post stays editable after publishing. Editing also closes with the first like, repost or reply, whatever this value says (an edit would silently rewrite what somebody else endorsed); deleting is never blocked. Raise it for a closed community where posts get little immediate engagement |
| `POST_DRAFT_RETENTION_DAYS` | `30` | How long the composer keeps a post somebody started and never sent, counted from the last change. Drafts are stored so a page reload cannot eat them, which means unpublished text of your members sits in your database — this is the retention promise your privacy page should quote. A draft is dropped the moment its post is sent, and any photo attached to it goes with it |
| `LANDING_HEADLINE_EXPERIMENT` | `true` | `false` stops the split test on the start page's founder quote: every visitor sees the same headline and nothing is counted. Leave it on and read the result at `/admin/experiments`, or turn it off if your start page copy is your own and you do not want it to vary. Only aggregate counters are stored, never a visitor, and the test sets no cookie of its own |
| `DATA_LOCATION` | `Deutschland` | Where your installation's data physically lives, named on the start page's privacy section ("on our own servers in X, not in somebody else's cloud"). **Set it to your own country or data centre, or to an empty value to drop that claim entirely** — which is what you must do if you run vutuv on rented cloud infrastructure, since the sentence says *our own servers*. The three promises beside it are properties of the software and stay whatever you set here: vutuv sets one first-party cookie and loads nothing from another host, every member can download their data from their settings at any time, and every member can delete their own account |
| `LANDING_EXAMPLE_PROFILE_URL` | `https://vutuv.de/wintermeyer` | The one profile the start page offers as "try it out" beside the screenshots, and the profile its machine-readable format chips (Markdown, text, JSON, XML, vCard, RSS) point at. A full URL, because the default has to keep working on an installation that has no filled-in profile yet — pointing at the reference installation is more useful there than a dead local link. Point it at one of your own members once you have one, or set it empty to drop the line and the chips (the installation-wide `/llms.txt` chip stays) |
| `FEDIVERSE_ENABLED` | `true` | `false` turns follow-only ActivityPub federation off entirely (endpoints 404, nothing is delivered, and the sign-up form drops the Fediverse question) — set it on intranet installations |
| `MASTODON_API_ENABLED` | `true` | `false` turns the Mastodon-compatible phone-client adapter off on **both** hosts it is served from. It answers on `PHX_HOST` — which is the address members actually type into an app — and on `mastodon.<PHX_HOST>`, the origin this app prefers. The subdomain is optional and nothing advertises it: it needs a DNS record, a TLS certificate and an nginx `server_name`, and without all three the adapter still works on the main host with nothing anywhere pointing at the name you did not set up. Give it a record only together with the certificate and the `server_name` — a name that resolves but is not served lands on whatever default virtual host answers on that address, which is somebody else's site with somebody else's certificate. A redirect between the two would not do, because HTTP libraries drop the `Authorization` header across a host change. Handles and ActivityPub actors are on `PHX_HOST` either way. Access is **off per identity by default**: each member turns it on under `/settings/apps`, each organization owner under `/organizations/<slug>/apps`, and either can turn it off again, which takes effect on the next request. `/system/mastodon` is the member-facing help page |
| `WEB_PUSH_ENABLED` | `true` | Web Push, so a member's phone is woken by a notification instead of an app polling for one — which is the cheaper side for your server too. It serves **two** kinds of client: Mastodon-compatible phone apps, and your site itself once somebody installs it on a Home Screen (it registers a service worker at `/sw.js`; on an iPhone that is the only way a notification is possible at all, and only for an installed app, never an open Safari tab). It needs **no configuration**: a VAPID key pair is self-signed, so an installation that was given none derives its own from `SECRET_KEY_BASE`. Set this to `false` on an installation that must reach no push service at all (an intranet with no route to Google's or Apple's): the push endpoints then answer 403, `/api/v2/instance` names no key, the per-device switch on `/settings/notifications` is not offered, and nothing is sent. A push carries **no content** — it names the notification's kind and id, never a word of what was written; a phone client fetches the rest over the authenticated API, and the service worker draws a generic line per kind ("New message on vutuv"). Members opt in twice, deliberately: once for the account under `/settings/notifications`, then again per browser, because a subscription belongs to one browser and not to the account |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | *(derived)* | Pin the Web Push key pair instead of deriving it. Both or neither — half a pair is a signature no push service accepts. Worth setting if you rotate `SECRET_KEY_BASE` (the derived pair changes with it, and every phone has to re-subscribe) or if you move the installation to another machine's secret. Generate one with `mix run -e 'IO.inspect Vutuv.WebPush.generate_keys()'` and keep the private key secret |
| `VAPID_SUBJECT` | `mailto:<OPERATOR_EMAIL>` | The contact a push service sees in our signed requests, a `mailto:` or `https:` URL. Defaults to the operator address you already configured |
| `FEDIVERSE_TAG_HOST` | `tags.<PHX_HOST>` | The host a **topic's** fediverse address lives on, so `#elixir` here is `@elixir@tags.your-host` out there and anybody can follow the topic from their own server without an account with you. It needs its own WebFinger authority, which is the whole reason for a separate host: members and pages share one handle namespace here, and a tag `elixir` would otherwise want the same address as a member called `elixir`. **What you owe it: a DNS record, a certificate covering it, and the host in your nginx `server_name`** — an installation that federates already has all three for its main host. Nothing there is for reading: a browser that lands on it is sent to the same page on your main host, and a topic's address opens that topic's page, so the subdomain never shows up as a second copy of your site. Leave it unset unless you want a different subdomain; an air-gapped installation runs `FEDIVERSE_ENABLED=false` and needs none of it |
| `FEDIVERSE_INBOUND_CAPS` | `600,60` | `host,actor`: how many rows one remote server, and one remote account, may store here per hour. Anything past the budget is dropped for that hour. The floor under the operator blocklist at `/admin/fediverse`, since it also bounds servers nobody has blocked yet |
| `FEDIVERSE_NOTE_RETENTION_DAYS` | `183` | How long a reply written on another network may be held here at the very most, in days. It is deleted when the clock runs out whatever else happens, so this is the promise your privacy page can make. Applies once a member has replies on — which the ticked Fediverse box at sign-up does, and the settings switch on its own does not |
| `FEDIVERSE_NOTE_REFRESH_DAYS` | `7` | How stale a stored reply may get before vutuv asks its origin server whether it is still published there. Still there means the text is refreshed and the retention clock starts again; gone (or locked away) means it is deleted at once; unreachable changes nothing. Replies sent to a member privately are never re-checked |
| `FEDIVERSE_OUTBOUND_REPLY_LIMIT` | `30` | How many answers to other networks one member may send per hour. This is the one place a member's own action makes your installation POST to a server that never followed them, so it is metered: the budget is the backstop against a compromised account relaying. Sized for somebody holding a conversation, so it only ever bites automation. Answering is only possible where a reply from that server already sits on a vutuv post, so the targets are always people who wrote here first |
| `FEDIVERSE_OUTBOUND_LIKE_LIMIT` | `200` | How many likes of posts on other networks one member may send per hour. A separate, far larger budget than the reply limit above, because the two are nothing alike in frequency: a like is one tap while reading, so a limit sized for writing prose would refuse ordinary reading. It is still a limit, because this too makes your installation POST to a server that never followed the member. Taking a like back is never metered: a withdrawal must not be refusable |
| `FEDIVERSE_OUTBOUND_BOOST_LIMIT` | `100` | How many posts from other networks one member may reshare per hour. Sits between the reply and like budgets, because a reshare is what those two are not: a publishing act (everyone following the member here and out there sees it) triggered by a single press while reading. A reshare is also what holds a cached post past its six-month ceiling, so it carries an ongoing cost as well as an outbound one |
| `FEDIVERSE_ANNOUNCE_FETCH_LIMIT` | `60` | How many posts announced by a followed account may be fetched from one remote host per hour. This is the only inbound activity that makes your installation fetch from a **third** server it has never spoken to, at an address that server did not choose, so it is metered per host: a busy account boosting relentlessly must not be able to walk you through a stranger's whole archive. A fetch that is refused, fails or is capped drops that boost silently — there is no retry, because a boost is not worth a queue |
| `FEDIVERSE_LOOKUP_LIMIT` | `30` | How many posts one member may **look up by pasting a URL** per hour (issue #1211), from the search box or from `/system/fediverse/lookup`. ActivityPub delivers only what an account posts after a follow is accepted, so this is how anything older reaches your installation at all: the member pastes the address of a post they are reading, vutuv fetches it once with a signed, SSRF-fenced, size-capped GET and caches it like any other. It works for **any** account, not only followed ones, which is why it is metered per member rather than per host — the address is the member's own choice, and what has to be bounded is one account turning your installation into a crawler. A post already cached here costs nothing from the budget, so re-opening the same one is free however often it happens. Everything else is the ordinary path: the operator blocklist, public and unlisted posts only, and the same six-month retention clock, counted from the lookup |
| `FEDIVERSE_POST_RETENTION_DAYS` | `183` | How long a post by an account one of your members follows may be cached here, in days. Since issue #1161 those posts appear in the follower's home feed, which means storing them. An upstream edit or deletion is honoured at once, and the cache is dropped the moment nobody here follows the author any more — this is the backstop under both. **One exception, since issue #1166:** a post one of your members has *reshared* is spared by both sweeps, because a reshare is a standing claim that this is worth showing and pulling it out from under readers on a calendar rule would be the wrong call. That copy is instead re-verified against its origin every few days: still published extends the clock, gone or narrowed upstream deletes it (and withdraws the reshare). If verification falls behind for a month the exemption lapses and the copy expires normally, so a backlog can never turn into indefinite unverified retention. **A second, narrower exception since issue #1211:** a post one of your members *looked up by its URL* usually has no follower at all — that is the point of the lookup — so it is spared by the "nobody follows the author" sweep. It is **not** spared by the clock: this exemption buys the copy the right to live out these six months, never a day more |
| `FEDIVERSE_MEDIA_MAX_BYTES` | `8000000` | The per-file ceiling on a **picture downloaded from another network** (issue #1163): a followed account's avatar and its posts' image attachments. A picture is the one thing here whose size is the attack, so the download is halted at this limit rather than buffered and measured afterwards; anything over it is not stored and the card says the picture is unavailable rather than promising a check that will never run (issue #1803). **These pictures pass the same AI image gate member uploads do** and are invisible until it clears them, so an installation running `IMAGE_MODERATION_ENABLED=true` needs the vision model available (`ollama pull qwen3-vl:8b`) or nothing from another network will ever be shown |
| `FEDIVERSE_REMOTE_FOLLOW_LIMIT` | `30` | How many **follow requests to accounts on other networks** one member may send per hour. Members can follow outward since issue #1160: they paste an address, vutuv resolves it over WebFinger and sends a signed `Follow`. The budget is the abuse backstop, so a compromised account cannot walk a whole server's member list; sized for somebody adding the people they read, so it only ever bites automation |
| `FEDIVERSE_MAX_REMOTE_FOLLOWS` | `1000` | How many accounts on other networks one member may follow in total. Every accepted follow is a standing invitation for that server to deliver here, so this is the ceiling on how much inbound traffic one member can subscribe your installation to. Raise it for a small, trusted installation; lower it if inbound volume is the concern |
| `FEDIVERSE_COUNTS` | `true` | Whether your installation asks other servers how many people liked or reshared the posts it has cached (issue #1283). Nothing about a third party's post is ever delivered here, so the only way to show a real figure is to fetch the object and read its `likes` / `shares` collections; this is that background job. `FEDIVERSE_COUNTS=false` stops asking — figures already stored keep rendering, they simply stop moving. Set it on an installation that wants to talk to other servers as little as possible |
| `FEDIVERSE_COUNTS_LADDER` | `30:5,90:10,360:15,2880:60,10080:360` | How often those figures are re-asked, as `age:interval` pairs in **minutes**, youngest first. The default reads: for the first half hour ask every five minutes, for the hour after that every ten, then every quarter of an hour to six hours old, every hour to two days, every six hours to one week, and never again after that. The head is fine-grained because that is when a post's tally actually moves. This is the knob that decides how much traffic your installation sends to servers that get nothing back, so lengthen it to be a quieter neighbour. Five minutes is a deliberate floor — the servers that serve these collections advertise a three-minute cache lifetime, so a five-minute ask still sits outside what they expect to be re-asked within — and the last tier ends the asking entirely, because an old post's tally has stopped moving |
| `FEDIVERSE_COUNTS_BATCH` | `60` | How many cached objects one refresh run (every two minutes) may ask about. Protects your own machine as much as anybody else's: a backlog drains over several runs instead of in one spike. The run interval is deliberately well under the ladder's shortest tier: a run stamps an object a few seconds after it became due, so polling *at* the tier length would leave it a few seconds short on the next run and silently double the real interval |
| `FEDIVERSE_COUNTS_PER_HOST` | `10` | How many of that batch may belong to a single host, so one instance that happens to host many of the accounts your members follow is spread over several runs rather than fetched in a burst. What the cap holds back is written to the log |
| `FEDIVERSE_IMAGE_HOLD_SECONDS` | `90` | How often a post whose picture the AI image scan has not judged yet looks again before it federates. A post never travels with a picture the scan has not cleared: it goes out the moment the scan settles (normally within seconds), and while the scanner is down it simply waits, re-checking at this interval, for as long as it takes. Lower it if you want held posts to leave sooner after a slow verdict; irrelevant when `IMAGE_MODERATION_ENABLED` is off |
| `NODE_NAME` | `vutuv` | What the fediverse directories call your installation. They fetch `/.well-known/nodeinfo` on their own and print this string beside the entry, so make it the name you want people to see in a list of servers — your organization, your community, your domain. It is also what a phone writes under the icon when somebody installs your site from the browser (the web app manifest at `/site.webmanifest`), so keep it short enough to read there |
| `NODE_DESCRIPTION` | (see below) | The sentence or two those directories print under the name. Keep it short — real entries run 10 to 20 words and the sites truncate — and say what your installation is *for*. The default claims only what is true of vutuv wherever it runs (open source, no tracking, no third-party cookies), so it stays honest if you never touch it, but it says nothing about *you*. **Where your servers stand is not part of this string**: vutuv appends that sentence from `DATA_LOCATION`, so clearing that one variable removes the hosting claim from your start page and from this document together. NodeInfo has no notion of language, so write it in the one your visitors read. **The install dialog does not use it**: unlike `NODE_NAME`, which names the Home Screen icon, the sentence a phone prints under that name when somebody installs your site is vutuv's own translated pitch, because this string has no language and that document is served per `Accept-Language` |
| `ACCOUNT_EVENT_RETENTION_DAYS` | `365` | How long the **account-activity log** keeps an event, in days (see `docs/architecture/account-activity.md`). It records what changed on an account, when, from which coarse device (never an IP address), and how it was confirmed, so it is personal data with a clock on it: a year covers the "this happened months ago and I only noticed now" support case without becoming a permanent movement profile. The daily sweeper deletes anything older |
| `FETCH_BOOK_METADATA` | `true` | `false` turns the catalogue lookups behind post **book reviews** off (the cover image, page count and publisher from Open Library, and an audiobook's running time). New reviews can no longer be created (the composer's review form was removed), but existing review posts keep rendering their card — with the flag off it shows no cover and none of those details. Set it on installations that must not call out (intranets) |
| `DNB_SRU_URL` | `https://services.dnb.de/sru/dnb` | Where an **audiobook's running time** is looked up by ISBN: an SRU endpoint answering MARC21-xml (the Deutsche Nationalbibliothek by default — Open Library records no durations). Point it at another catalogue's SRU endpoint, or set it **empty** (`DNB_SRU_URL=`) to switch that one lookup off while the rest of the book metadata keeps working |
| `AMAZON_DOMAIN` | `www.amazon.de` | The store a book review card's shop link points at (`https://<domain>/dp/<isbn10>`). Set your regional store (`www.amazon.com`, …) — or an **empty** value (`AMAZON_DOMAIN=`) to remove the shop link entirely |
| `AMAZON_AFFILIATE_TAG` | – | Optional Amazon affiliate tag appended to book review shop links as `?tag=` |
| `AUDIBLE_DOMAIN` | `www.audible.de` | The Audible store an **audiobook** review card links the "Hörbuch"/"Audiobook" word to (a title search, since Audible keys by its own ASIN, not the print ISBN). Set your regional store (`www.audible.com`, …) — or an **empty** value (`AUDIBLE_DOMAIN=`) to keep the word plain text |
| `VERIFY_ORGANIZATION_DOMAINS` | `true` | `false` disables the verified-organization-page domain proof (the DNS TXT and well-known-file checks and their periodic re-check) — no new organization page can be verified, existing ones keep working. Set it on installations that must not make outbound DNS/HTTP calls. A newly verified organization sends an operator notice to `OPERATOR_EMAIL` |
| `VERIFY_USER_LINKS` | `true` | `false` disables verified personal-webpage links (a member proving a profile link is their own page via a rel=me back-link, or the same DNS TXT / well-known-file domain proof, plus their periodic re-check) — no new link can be verified, existing marks keep working. Set it on installations that must not make outbound DNS/HTTP calls |
| `VERIFY_SOCIAL_ACCOUNTS` | `true` | `false` disables verified social-media handles (a member proving a listed account is theirs, plus its periodic re-check) — no new account can be verified, existing marks keep working. Two kinds of account can be proved: Bluesky (its profile description must carry the member's vutuv profile URL, which the public Bluesky AppView is asked for) and a self-hosted Gitea/Forgejo profile (the website field or the description, read from that instance's public API). Set it on installations that must not make outbound HTTP calls |
| `GITHUB_API_TOKEN` | – | Optional token for the profile code-stats fetches (GitHub allows 60 unauthenticated requests/hour per IP; a token raises that to 5,000). A [fine-grained PAT](https://github.com/settings/personal-access-tokens) with **no** scopes/permissions is enough — the fetches read public data only. Can be added (or rotated) at any time; without it everything still works, the 7-day snapshot cache is sized for the unauthenticated limit |
| `MAIL_LOG_POLL_MS` | `5000` | Bounce watcher poll interval |
| `JOB_RUNTIME_DAYS` | `90` | How long a published job posting stays live before it auto-expires. Flat, no renewals — a still-open role gets a fresh posting |
| `JOBS_MAX_PER_MEMBER` | `3` | Most concurrently-published job postings for one member (anti-abuse) |
| `JOBS_MAX_PER_ORG` | `10` | Most concurrently-published job postings for one organization |
| `COLD_OUTREACH_LIMIT` | `20` | Anti-spam cap on how many new message *requests* one member may open to strangers (members who don't already follow them) within the window. Replying to an accepted thread never counts. A member over the cap gets a friendly "try again later"; admins see the counter on a poster in the `/admin/jobs` detail drawer |
| `COLD_OUTREACH_WINDOW_HOURS` | `24` | The window, in hours, over which `COLD_OUTREACH_LIMIT` is measured |
| `SAVED_SEARCHES_MAX_PER_MEMBER` | `10` | Most saved searches (with e-mail alerts) one member may store (anti-abuse). A member at the cap is asked to delete one first |
| `GEO_COUNTRIES` | `DE,AT,CH` | Comma-separated ISO 3166-1 alpha-2 codes whose bundled GeoNames postal data is loaded for offline zip → coordinate resolution on job postings. To add a country, drop its GeoNames zip export (`download.geonames.org/export/zip/<CC>.zip` → extracted `<CC>.txt`, optionally gzipped to `<CC>.txt.gz`) into `priv/geo/` and add the code here. Fully offline — no outbound calls |
| `IMAGE_MODERATION_ENABLED` | `true` | `false` turns AI image moderation off (images publish immediately, as before the feature). While enabled, **every** image — avatars, covers, post / job-posting / organization images and the automatic link and homepage screenshots — waits invisible to everyone but its owner until a local Ollama vision model approves it; an unsafe image is deleted on the spot and the owner notified. Fail-closed: with Ollama unreachable, new images queue up and are scanned automatically once it is back — nothing is ever auto-approved. Set `false` only on installations without Ollama |
| `IMAGE_PIXELATION_WINDOW_SECONDS` | `3600` | How long a picture waiting for that verdict shows readers a **pixelated preview** of itself — a separately stored file reduced to 64 cells on its long edge, not the picture behind a blur filter, so what reaches a reader carries none of the detail. It keeps a post card whole while the scan runs, and the real picture replaces it live the moment the verdict lands. Past this window the card falls back to a grey "being checked" tile, so a derivative of an unvetted picture never sits on a public page indefinitely. `0` switches the pixelated preview off entirely, which is the strictest posture |
| `OLLAMA_URL` | `http://localhost:11434` | Base URL of the Ollama instance every AI feature talks to (image scan, translations, tag merge assist, employment-reference analysis). May be a **comma-separated list** (`http://gpu-box:11434,http://second-gpu:11434,http://localhost:11434`), which is read two ways at once. For a single call it is a **priority list**: every instance but the last is tried with a 30 s budget and skipped on any failure, the last one is the patient fallback (120 s, covers a CPU cold load). For calls that overlap it is also a **pool**: the second one starts on the least busy instance, so a second GPU takes work rather than waiting for the first to break. Verdicts are identical either way — the list only buys speed |
| `OLLAMA_CONCURRENCY` | all `OLLAMA_URL` entries but the last | How many instances at the head of the list are treated as workers — which is both how deep the pool goes and how many calls a background sweep may have in flight. The default holds the **last** entry back as the fallback of record, because that is typically the web server's own CPU Ollama: `http://gpu-box:11434,http://localhost:11434` is one worker (unchanged from before this existed), `http://gpu1:11434,http://gpu2:11434,http://localhost:11434` is two. Set it to the number of entries when the list is all GPUs and nothing is held in reserve, or higher when one box can genuinely run two calls at once |
| `OLLAMA_VISION_MODEL` | `qwen3-vl:8b` | The vision model used for the safety verdict. Pull it once (`ollama pull qwen3-vl:8b`); any Ollama vision model works (`qwen3-vl:4b` halves the load on CPU-only servers) |
| `IMAGE_SCAN_VOTES` | `3` | How many opinions the vision model gives on an image it called **unsafe**. The first answer is deterministic and decides alone when it says "safe" (so an ordinary upload costs one inference); a suspicion buys this many opinions in total, sampled so they are genuinely independent. Raising it makes borderline cases slower but steadier |
| `IMAGE_SCAN_REJECT_VOTES` | `3` | How many of those opinions must call the image unsafe before it is really deleted. The default is unanimous out of three: a model's answer on a harmless-but-dramatic picture (a cartoon skull, a horror-film still, a joke image) flips between runs, and deleting a member's picture on a coin flip is the worse error — a released image is still reportable by every reader. Set both vote variables to `1` for the old "one answer decides" behaviour, or lower this to `2` for a stricter installation |
| `TRANSLATE_POSTS` | `false` | `true` enables on-demand post translations: a reader taps "Translate" on a foreign-language card (or sets their feed to auto-translate), a job queues, a local Ollama text model translates, and the result is cached per post + target language. No translation is pre-computed, translations never federate, and public/logged-out/agent surfaces always show the original. Fail-open: with Ollama unreachable the card simply keeps showing the original. It also turns on **language detection** for posts that declare none (the pile from before the language column existed, and remote posts whose origin sends no `contentMap`) — a cheap one-field call per post, a couple of posts per poll, which is what makes a member's feed-language choice apply to old posts at all. Leave off on installations without an Ollama that can carry the model |
| `OLLAMA_TRANSLATION_MODEL` | `gemma4:31b` | The text model that translates posts. Deliberately separate from the vision model: the eval (issue #1455) found the smaller/faster text models invert negations — fluent, wrong translations — while gemma4:31b made no meaning errors. Pull it once (`ollama pull gemma4:31b`, ~20 GB); speed barely matters, the queue is async |
| `PRECOMPUTE_TRANSLATIONS` | `true` | Whether this installation also translates **its own posts** in the background, into every locale it serves, so a reader who taps Translate usually gets an instant cache hit instead of waiting for the model. Only takes effect with `TRANSLATE_POSTS=true`. It is deliberately the slowest thing on the box: at most 20 of its jobs are ever queued, every one of them ranks behind every reader's request, and it stands down completely while image moderation has a picture waiting. Set `false` to keep translation on demand only — worth doing if your Ollama has other work, or if it is a CPU-only instance |
| `TAG_MERGE_ASSIST` | `true` | Whether the tag merge screen (`/admin/tag_merges`) may ask a local model which of its proposed tag pairs name one topic. It only ever **proposes**: an admin approves each merge and sees what it would move first. With this `false` (or Ollama unreachable) the queue still fills from the deterministic rules and is administered by hand, which is the air-gapped case. The one thing it costs: a pair found only because the two names share a word (`Linux` / `embedded linux`) is left out unless a model has vouched for it, since unjudged it is nearly always wrong |
| `TAG_MERGE_ASSIST_MODEL` | `qwen3.5:9b` | The text model that judges those pairs. Pull it once (`ollama pull qwen3.5:9b`); it is asked one narrow question per pair and told to answer "different topics" whenever unsure |
| `DEFAULT_COUNTRY` | `DE` | ISO 3166-1 alpha-2 code that preselects country inputs (job postings, organization pages, employment references) |
| `REFERENCE_CHECKS_ENABLED` | `true` | Whether members may have an uploaded Arbeitszeugnis reviewed by a text model. Off = they can still upload, attach and publish references; only the review disappears |
| `REFERENCE_CHECK_MODEL` | `qwen3.6:27b` | The text model that performs the review. Pull it once (`ollama pull qwen3.6:27b`). A smaller model fits the prompt but grades German wording measurably worse |
| `REFERENCE_CHECK_MODEL_URL` | derived | Where the "how the review works" box links the model tag it names, so a member can check the "freely available" claim instead of taking it on trust. Left unset it is worked out from the tag: `qwen3.6:27b` → `https://ollama.com/library/qwen3.6:27b`, `someone/model:7b` → `https://ollama.com/someone/model:7b`, `hf.co/user/repo:Q4_K_M` → `https://huggingface.co/user/repo`. A model from a private registry, or one you built yourself with `ollama create`, has no page anywhere we can guess, so it is named without a link — set this to give it one, or to an empty string to say plainly that there is none |
| `REFERENCE_CHECK_NUM_CTX` | `65536` | **Not a tuning knob.** The analysis prompt is ~35,200 tokens and Ollama does not refuse a window too small for it — it silently truncates and answers anyway. Measured: at `32768` the model saw 16,386 of 35,559 tokens and produced a polished report with no § 109 GewO and no Beweislast in it. vutuv refuses to run below what it needs and rejects a reply whose token count shows a truncation, but this is the value that makes it work rather than fail |
| `REFERENCE_CHECK_TIMEOUT` | `900000` | Milliseconds one review may take. 15 minutes covers a CPU-only instance; measured ~45 s on a warm GPU, ~11 minutes on 32 CPU cores |
| `REFERENCE_CHECKS_PER_DAY` | `10` | Reviews one member may start inside a **rolling 24 hours** (not a calendar day, so a member who uses their last slot at 23:00 is free again at 23:00 the next day). A review occupies the model for minutes and a typical Ollama answers one request at a time, so this is the brake that keeps one member from filling the queue for everybody. The refusal tells the member how long is left, computed from the same window |
| `REFERENCE_CHECK_HARDWARE` | `NVIDIA GPU` | What the "how the review works" box on `/settings/job_references` calls the machine the review runs on. That box exists to promise a member that their Zeugnis never leaves your installation, and naming the hardware makes the promise concrete — so it must be **true of your installation**. Running Ollama on CPUs or on another vendor's card? Set your own wording, or an empty string to drop the clause and keep the plain "on our own servers" |
| `REFERENCE_CHECK_COUNTRY` | `DE` | ISO 3166-1 alpha-2 code of the country your servers stand in, named in the same box ("on our own servers in Germany"). A code rather than a word, so it is shown in each reader's own language. Empty drops the clause. Set it to where the machine running Ollama really is, which is not necessarily where your company is |
| `FETCH_REFERENCE_SKILL` | `false` | Whether the analysis prompt is re-fetched daily from its upstream repository. **Off by default**: the prompt ships in `priv/reference_skill/SKILL.md`, so the reviewed copy is the one that runs, a change to it is a reviewable commit, and the review keeps working with no outbound network at all. Set it to `true` only if you want upstream corrections without waiting for a deploy — accepting that the text producing your members' legal readings can then change overnight without review |
| `REFERENCE_OCR_MODEL` | `qwen3.5:9b` | The vision model that reads a scanned reference. **Not** the same as `OLLAMA_VISION_MODEL`: image moderation wants a fast verdict on a picture, transcription wants every word exactly as written. Measured on a real Zeugnis template, `qwen3-vl:8b` (the moderation default) read "vollsten Zufriedenheit" as "vollen" — the difference between the top grade and the second, in flawless German nobody would query. Pull it once (`ollama pull qwen3.5:9b`) |
| `REFERENCE_OCR` | `auto` | How a scanned reference is read: `auto` (Tesseract if installed, else the vision model), `tesseract`, `vision`, `off`. Tesseract goes first despite scoring worse overall, because its mistakes look like mistakes while a vision model normalises plausibly — in testing it turned "Kundenstammdaten" into "Kundendaten", and in a document where one word carries the grade a visible error is the safer one. Install `tesseract-ocr` and `tesseract-ocr-deu` to use it |

The defaults marked **Set this** are vutuv.de's operator identity — a fresh
installation should override all of them on day one, or your daily reports
will try to reach vutuv.de's operator.

A few rarely-changed switches are compile-time settings in
`config/config.exs` / `config/prod.exs` (edit before `mix release`):
`:ads_enabled` (the daily text-ad system, off by default),
`:ai_crawler_policy` (`:permissive` or `:block_training` — drives robots.txt
and the Content-Signal headers), `:fetch_gravatar`, `:fetch_mastodon_posts`,
`:fetch_bluesky_posts`, `:fetch_code_stats` (the profile "Code" card's
GitHub/GitLab/Codeberg and self-hosted Gitea/Forgejo statistics), `:generate_screenshots` (profile link
previews, an organization page's homepage capture **and** the auto-screenshot
for single-link posts, including cached
fediverse posts in the feed — admins watch the
capture queue and browse the gallery at `/admin/screenshots`; a YouTube video
link stores the video's published thumbnail instead of a capture, fetched
server-side from YouTube under this same flag),
`:fediverse_quote_resolve` (resolving what an incoming fediverse post
**quotes** — see [fediverse.md](architecture/fediverse.md); on, it fetches the
quoted post and its consent stamp so the quote renders as a card, off it stays
the plain link it arrived as, and either way nothing happens while
`FEDIVERSE_ENABLED` is false; the flag also runs the two-minute sweeper that
picks up the resolutions a deploy or a crash interrupted), and
`:serve_uploads_locally` (see nginx below).

## systemd

A template unit for the reference installation lives in
[`scripts/systemd/vutuv3@.service`](../scripts/systemd/vutuv3@.service)
(vutuv.de runs two of them for blue/green deploys). A minimal single-slot
unit:

```ini
[Unit]
Description=vutuv
After=network.target postgresql.service

[Service]
User=vutuv
EnvironmentFile=/srv/vutuv/shared/.env
ExecStart=/srv/vutuv/current/bin/vutuv start
ExecStop=/srv/vutuv/current/bin/vutuv stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## nginx

The app listens on the loopback (`PORT`); nginx terminates TLS and proxies
everything to it. LiveView needs websocket upgrades:

```nginx
server {
    server_name example.com;

    # HSTS: tell the browser to only ever reach this host over https, so it
    # never sends the login-session cookie (`_vutuv_key`) over cleartext http —
    # closing the very first-request window that the cookie's own `Secure` flag
    # cannot cover. Only add this on a TLS (https) vhost; an intranet install
    # served over plain http must NOT set it. `includeSubDomains` covers every
    # subdomain; drop it if any subdomain is intentionally http-only.
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:4003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    # LinkedIn-import archives and post photos may each be up to 50 MB (the app
    # enforces its own caps). Keep this above both, or a member's camera JPEG is
    # refused by nginx before the app ever sees it.
    client_max_body_size 64m;
}
```

The app itself does **not** send `Strict-Transport-Security` and does **not**
enable `Plug.SSL`/`force_ssl`: the blue/green deploy's health gate curls
`http://127.0.0.1:$PORT/health` on loopback with no `X-Forwarded-Proto`, which
`Plug.SSL` would redirect and break the deploy. HSTS therefore belongs here in
the nginx TLS terminator, which every internet install already runs.

### Static assets (optional, but worth it on a slow link)

By default every `/assets/` request is proxied to the app, which serves the
file uncompressed and lets nginx compress it again on each request. If you let
nginx read the files itself instead, it can hand out the brotli and gzip copies
the deploy already wrote and skip the app entirely.

`mix assets.deploy` produces content-hashed names (`app-<md5>.js`), so a file
never changes under its own URL and two releases' assets can sit side by side.
`scripts/publish-static.sh <path-to-priv/static>` copies a release's tree to
`STATIC_DEST` (default `/srv/vutuv3/static`) and writes a `.br` and a `.gz`
beside every text file; `scripts/deploy.sh` calls it before the traffic switch.

It wants two packages, and works without either: **`brotli`** for the `.br`
half (no brotli binary, no `.br` files, and nginx simply compresses per request
as before), and **`zopfli`** for the `.gz` half. zopfli emits an ordinary gzip
stream every client already understands, about 3 % smaller than `gzip -9`
(measured on the production bundle: 207,884 bytes against 215,079) for a couple
of seconds of CPU per megabyte — worth it here only because this runs once per
deploy rather than per request. Without zopfli the script falls back to
`gzip -9`. Point nginx at that directory:

```nginx
# Only the digested names, because only a content-hashed URL may claim
# `immutable`. The undigested siblings (app.js, app.css) keep their URL while
# their content changes, so they fall through to the app. The five roots are
# exactly Plug.Static's `only:` list, so this can never shadow an application
# route; /images/ is in there because the logo and wordmark SVGs are digested
# too and load on every page.
location ~ "^/(assets|css|fonts|images|js)/.+-[0-9a-f]{32}\.[A-Za-z0-9]+$" {
    root /srv/vutuv3/static;
    brotli_static on;          # needs the ngx_brotli module; omit if absent
    gzip_static on;
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    try_files $uri @app;
}

# Fallback for an asset the publish step has not written yet.
location @app {
    proxy_pass http://127.0.0.1:4003;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

The `try_files` fallback is what makes this safe to add at any time: nothing
404s while the directory is empty, and a deploy never has to land the files
before the code that names them.

Two settings in the `http` block are easy to get wrong. **`gzip_types` defaults
to `text/html` alone**, so `gzip on` by itself leaves JavaScript and CSS
uncompressed for any client that does not offer brotli; list the text types
explicitly. And set `gzip_vary on` so responses carry
`Vary: Accept-Encoding` — without it a shared cache may hand a compressed body
to a client that never asked for one.

### Uploaded images

Avatars, cover photos and URL screenshots are **public** images served
straight off disk. Give the vhost one prefix-location `alias` per directory,
all three pointing into `UPLOADS_DIR_PREFIX`. **All three are required** — a
missing block means those images 404 even though the file exists on disk,
because the request falls through to the app, which does not serve them:

```nginx
location /avatars/ {
    alias /srv/vutuv/uploads/avatars/;
    expires 30d;
    add_header Cache-Control "public";
}
location /covers/ {
    alias /srv/vutuv/uploads/covers/;
    expires 30d;
    add_header Cache-Control "public";
}
location /screenshots/ {
    alias /srv/vutuv/uploads/screenshots/;
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

The private `originals/` tree under `UPLOADS_DIR_PREFIX` must **not** get any
`location`/`alias`: uploaded originals (with their EXIF/GPS metadata) are
never served, by design.

**Post images need no nginx setup**: they are audience-guarded, so the app
authorizes and serves them itself (`send_file`).

Running without nginx aliases is possible: set
`config :vutuv, :serve_uploads_locally, true` **and**
`config :vutuv, :uploads_dir_prefix, "/your/uploads"` in `config/prod.exs`
before building (both are compile-time in this mode), and the app serves
those directories itself.

## First steps after installation

1. **Check email works.** Register an account on your installation — the
   confirmation PIN must arrive. Nothing else works until SMTP does.
2. **Make yourself admin:**
   `bin/vutuv eval 'Vutuv.Release.promote_admin("your-handle")'`
   (or `mix vutuv.admin.promote your-handle` in a source checkout). The admin
   panel appears in your account menu, at `/admin`.
3. **Write your legal pages** at `/admin/legal` — Impressum,
   Datenschutzerklärung and Nutzungsbedingungen. A fresh installation shows a
   neutral "not published yet" placeholder on those pages until you do. If you
   operate in Germany, publishing an Impressum and a privacy policy is a legal
   requirement, and the texts must name **you**, not vutuv.de's operator.
   The body is Markdown; vutuv.de's own texts can serve as a structural
   reference (`priv/repo/seed_data/legal/`), but the legal content is your
   responsibility.
4. **Review the operator variables** (`OPERATOR_*`, `MAILER_FROM_ADDRESS`,
   `BOUNCE_ADDRESS`) so system mail carries your identity, not vutuv.de's.
5. **Set `NODE_NAME` and `NODE_DESCRIPTION`** if your installation is on the
   internet — that is how the fediverse directories will name and describe it
   (see below). The defaults describe vutuv.de.

## Intranet installations

vutuv runs fine without internet access:

- Set `PHX_SCHEME=http` if the intranet has no TLS (and `PHX_HOST` to the
  internal host name). With TLS, nothing special is needed.
- Set `FEDIVERSE_ENABLED=false`: follow-only ActivityPub federation delivers
  posts to remote servers and fetches remote actor documents — pointless and
  noisy without internet access.
- Set `WEB_PUSH_ENABLED=false`: Web Push needs no configuration and is
  therefore on, so the first phone client — or the first member who installed
  your site on a Home Screen — that registers a subscription would have your
  server signing requests to Google's or Apple's push service. Off, the push
  endpoints answer 403, the instance document names no key and the per-device
  switch on `/settings/notifications` is not shown, so nothing offers push in
  the first place. (`MASTODON_API_ENABLED=false` takes the *phone-client* half
  with it, if you turn the whole adapter off; it deliberately does not silence
  a member's own installed app, which does not use that API.) Everything else
  the service worker does — the offline page and the asset cache — is local and
  keeps working.
- Consider `VERIFY_ORGANIZATION_DOMAINS=false`: the verified-organization-page domain
  proof (DNS TXT + well-known file) needs to reach the domain being verified.
  On an intranet the DNS TXT method still works against an internal resolver,
  but the well-known fetch is blocked by the SSRF guard for internal hosts; set
  the flag to `false` to hide the feature entirely if organization pages are not
  wanted.
- Consider `VERIFY_USER_LINKS=false`: verified personal-webpage links (rel=me
  back-link, DNS TXT or well-known file) reach out to the member's page the same
  way, with the same SSRF guard against internal hosts. Set the flag to `false`
  to hide the feature if link verification is not wanted on the installation.
- Set `VERIFY_SOCIAL_ACCOUNTS=false`: verified social-media handles ask the
  public Bluesky AppView (`public.api.bsky.app`) for the account's profile
  description, or a self-hosted Gitea/Forgejo instance for its public user
  object, so unlike the link proofs there is no internal-resolver variant that
  could work air-gapped — the check simply fails. Turn it off so the verify
  page says so plainly instead of offering a button that can never succeed.
- Turn off the features that call out to the internet (compile-time flags in
  `config/config.exs`): `:fetch_gravatar` (the member's own "Fetch my picture
  from gravatar.com" button on `/settings/profile` — off, the button is not
  rendered at all; nothing contacts gravatar.com unless a member presses it,
  and registration never does),
  `:fetch_mastodon_posts` / `:fetch_bluesky_posts` (the social-feed card on
  profiles), `:fetch_code_stats` (the profile "Code" card's GitHub/GitLab/
  Codeberg and self-hosted Gitea/Forgejo statistics — off, the accounts stay
  plain links, and a self-hosted address is taken at its word because the
  instance cannot be asked), and
  `:generate_screenshots` (profile link-preview screenshots, an organization
  page's homepage capture **and** the auto-screenshot for single-link posts —
  these fetch the linked page and run headless Chromium).
- Set `FETCH_BOOK_METADATA=false`: the cover fetch and the
  page-count/publisher lookup behind book-review posts call Open Library, and
  an audiobook's running time is read from a library catalogue (`DNB_SRU_URL`).
  Existing book and film review posts keep rendering — the card just shows no
  cover and none of those details.
- AI image moderation works **fully offline** — Ollama is local inference, no
  cloud involved. Install Ollama on the server, pull the vision model once
  while you still have internet access (`ollama pull qwen3-vl:8b`), and keep
  `IMAGE_MODERATION_ENABLED=true`. Only an installation without Ollama should
  set it to `false` (images then publish unmoderated, as before the feature).
- The tag merge assistant works offline for the same reason (local inference),
  so `TAG_MERGE_ASSIST=true` is fine with Ollama installed. Without Ollama, set
  it to `false`: the merge screen still proposes the pairs its deterministic
  rules find and an admin decides them by hand, which is the whole feature minus
  the second opinion.
- Post translations are local inference too: with Ollama installed, pull the
  model once while you still have internet access
  (`ollama pull gemma4:31b`) and set `TRANSLATE_POSTS=true`. Without Ollama,
  leave the flag at its off default — every surface keeps showing originals,
  which is also exactly what happens if Ollama goes away later (fail-open).
  After switching it on, name the language of the posts already in the
  database in one go (the background poll would take days over a large
  archive) — it stops by itself when the pile is drained:

      bin/vutuv eval "Vutuv.Release.detect_post_languages()"

  Run that **before** you expect much from the background pre-translation: a
  post whose language nobody has placed is not a candidate for it, so on a
  fresh switch-on the sweep has almost nothing it is allowed to do until the
  detection pile is drained.
- The map links on profile addresses (Google/OSM/Apple) are plain link-outs
  rendered in the visitor's browser; they simply won't resolve offline.
- Job postings need no configuration to work offline: their zip → coordinate
  resolution uses a bundled GeoNames postal dataset (`priv/geo/`), entirely
  offline with no outbound call. Add your intranet's country with
  `GEO_COUNTRIES` if it is not one of the shipped `DE`/`AT`/`CH`.
- Search engines and AI crawlers are irrelevant on an intranet; the
  robots.txt / Content-Signal machinery does no outbound calls either way.

## Email deliverability (optional)

vutuv can detect hard bounces and stop mailing dead addresses: a watcher
tails the local Postfix log (`MAIL_LOG_PATH`), or an external detector can
POST to `/webhooks/bounces` (guarded by `BOUNCE_WEBHOOK_TOKEN`). Without
either, bounce handling is simply off and nothing else breaks.

**Prefer the log watcher.** The webhook acts on the DSN it is handed without
checking that this installation ever sent to the address, so piping a raw local
bounce mailbox into it lets anyone forge a bounce and freeze a member
([#1063](https://github.com/wintermeyer/vutuv/issues/1063)). The watcher has no
such hole: it only acts on a bounce it can tie back to our own outbound mail. On
a watcher-only setup, `BOUNCE_WEBHOOK_TOKEN` is not needed and can be left unset.

The full design, DSN taxonomy and a new-server runbook:
[`production-email-and-bounces.md`](production-email-and-bounces.md).

## Backups

Two things hold all state:

1. The PostgreSQL database (`pg_dump`).
2. The uploads directory (`UPLOADS_DIR_PREFIX`) — including the private
   `originals/` tree, from which every served image can be re-derived.

## Upgrades

```bash
git pull
MIX_ENV=prod mix deps.get --only prod && MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release
bin/vutuv eval "Vutuv.Release.migrate()"   # then restart the service
```

Migrations are kept backward-compatible for one release (vutuv.de deploys
blue/green with zero downtime — see [DEVELOPERS](DEVELOPERS.md)), so a simple
stop → migrate → start on a single server is always safe.

## Maintenance tasks

Run on the server, against the release:

- `bin/vutuv eval "Vutuv.Release.regenerate_images()"` — re-derives every
  served image version (AVIF) from the kept originals per the current
  `Vutuv.Uploads.Spec`. Idempotent; safe while the app serves traffic.
- `bin/vutuv eval "Vutuv.Release.refresh_review_covers()"` — re-fetches every
  book-review cover from Open Library, and with it the page count, publisher
  and audiobook running time (the backfill for reviews written before those
  were shown). Book covers are the one image kind
  vutuv keeps no original of (see "Book covers" below), so `regenerate_images`
  cannot re-derive them; this is their equivalent after an upgrade that
  changes the cover size. Needs outbound network and `FETCH_BOOK_METADATA=true`,
  and paces itself (3s per cover) to stay inside Open Library's rate limit.
- `bin/vutuv eval 'Vutuv.Release.promote_admin("handle-or-email")'` — grants
  admin rights.

(In a source checkout the same exist as `mix vutuv.images.regenerate` /
`mix vutuv.review_covers.refresh` / `mix vutuv.admin.promote`; URL screenshots
can be re-rendered with `mix urls.create_screenshots`.)

## Book covers on review posts

With `FETCH_BOOK_METADATA=true` (the default) a book review's cover is
downloaded once from Open Library by ISBN and stored on your server, then
served from there — never hotlinked, so no reader's IP reaches a third party.
Worth knowing as an operator:

- **The image rights do not come with it.** Open Library passes the covers
  through and states plainly that it asserts no rights over them and that
  "there may be existing rights issues"; the artwork belongs to publishers.
  vutuv treats a cover as a **quotation** beside a review (§ 51 UrhG in
  Germany, comparable rules elsewhere) and is built accordingly: it stores
  only the one small derived version it displays (max 320px, no
  full-resolution original), shows it only attached to a review post, credits
  the source under the cover with a link to the book's Open Library page, and
  serves every cover with `X-Robots-Tag: noindex, noimageindex` so it stays
  out of image search.
- **Removal is instant.** An admin rejecting the image in
  `/admin/moderation` deletes the stored files; deleting the post does too.
  Keep a contact address reachable (`OPERATOR_EMAIL`, your imprint) so a
  rights holder can ask.
- **Your call, your risk.** Whether that quotation argument holds in your
  jurisdiction is your decision as the operator, not vutuv's. If you would
  rather not host third-party covers at all, set `FETCH_BOOK_METADATA=false`:
  existing reviews keep rendering and the card shows a neutral 📖/🎬 tile
  instead.

Note: `bin/vutuv eval` is the supported console entry point; `rpc`/`remote`
need distribution, which the reference setup disables.

## Preference defaults

Some behaviour is a **member preference** with an installation-wide default:
how many lines a post shows in the feed before "Read more" (desktop and
mobile separately), whether post text hyphenates, how many lines of a post a
notification on `/notifications` quotes, which map services appear on
addresses and which one opens first. Members tune these on their own settings
pages; you decide what everyone gets **until** they do.

One is the **interface language**. vutuv ships in English, German and Italian;
a member picks theirs on their settings page, and a visitor who has picked
nothing gets whatever their browser asks for, falling back to English. The set
is a source-level list (`:locales` in `config/config.exs`), not an environment
variable, because a language is only served once its translations, its email
templates and its help pages exist — see
`docs/architecture/i18n.md` if you want to add one. Note that with
`TRANSLATE_POSTS=true` each served locale is also a pre-translation target, so
a third language means a third machine translation per local post.

Two others decide how every timestamp on the site is written: the **date
format** (`31.12.2026` / `31/12/2026` / `12/31/2026` / `2026-12-31`, each with
its own clock) and the **time zone**. They ship as German dates on Europe/Berlin
because that is what vutuv.de is; an installation somewhere else changes both
here once and every member who has not chosen follows. A member's own choice
always wins, and a **new account takes both from its browser at sign-up**, so
these defaults matter most to accounts that already existed and to logged-out
visitors. The time zone list is the IANA database compiled into the release —
nothing is fetched, so an air-gapped install has every zone.

Another is a privacy posture rather than a display detail: **whether a member
is named among the likes of a post**. A post's own page lists the
members who liked it under the count, and vutuv ships that as public, the way
a like is on the networks people come from. If your installation wants the
opposite — an intranet, say, where who agreed with what is nobody else's
business — turn *Show my name on posts I like* off at `/admin/preferences` and
every member who has not decided for themselves is unnamed, with the switch
still theirs to turn back on. It never changes the **count**: a post always
shows how many likes it got, whoever may be named.

A third is about how loud the feed is: **whether the source tabs quote what
lands on the one a member is not reading**. Something arriving on the tab they
are not on marks it with a dot either way; on top of that, the bar can quote
the arrival — author and first words — for a few seconds before folding back.
vutuv ships that on, at eight seconds. An installation that wants a quieter
feed turns *Quote what arrives on the other tab* off at `/admin/preferences`,
or shortens the window there; the dot is unaffected, and every member can set
both for themselves.

- **`/admin` → Preference defaults** (`/admin/preferences`): change the
  default for the whole installation at any time. It applies immediately to
  every member who has not set an own value — and to logged-out visitors.
  Each field notes the shipped default and how many members have customized
  it (those members are unaffected). Saving a value equal to the shipped
  default simply removes your override.
- **Per-member overrides** (member browser `/admin/users` → the row's
  **Preferences** button): set or clear one member's values for support, e.g.
  to reproduce a display complaint. Blanking a field puts the member back on
  the installation default. You are editing the member's own settings — they
  see and can change the same values on their settings pages, where a "Reset
  to the site defaults" link does the same clearing.

No configuration file or restart is involved; the defaults live in the
database and every node picks changes up immediately.

## Screenshot blocklist

vutuv screenshots the pages your members link to: every profile link gets a
preview thumbnail, a post that carries a single link and no picture gets a
preview of that page, and an organization page shows a capture of the website
it names.

The capture browser dismisses cookie-consent dialogs by itself. It always
answers them with **reject**, never accept, so nothing is consented to on a
member's behalf, and it needs no setup from you beyond the ordinary
`mix assets.setup` in a deploy. Some sites still make a preview pointless
though: a login wall, a bot check, or a "consent or subscribe" wall that
offers no reject at all (heise is one), so the shot is a picture of a dialog
whatever the browser tries. Those pages belong on the blocklist.

**`/admin` → Link screenshots → Blocklist** (`/admin/screenshots?tab=blocklist`)
is the editor. An entry is a domain or a URL:

| Entry | Covers |
| --- | --- |
| `heise.de` | the whole site: the domain, every subdomain (`www.`, `m.`), every path |
| `*.heise.de` | the same rule, spelled out |
| `example.com/news` | that path and everything below it (but not `/newsroom`) |
| `example.com/*/private` | `*` stands for exactly one path segment |
| `https://example.com/story-1` | one page; the scheme, a port, `?query` and `#fragment` are ignored |

A change takes effect immediately, on every node — no restart, no config file.
The tab also has a **Try a URL** box: paste a real link to see whether the
list covers it, which is the quickest way to check that a new entry does what
you meant.

Nothing breaks for a listed link. A post shows the plain link, and a profile
link shows the site's name where the thumbnail would be. Note that adding an
entry only stops **new** captures: a page screenshotted earlier keeps its
picture, because a link is re-captured only when its URL changes. The
**Remove them now** button on the same tab deletes the stored screenshots of
every page currently on the list; headless, that is
`bin/vutuv eval "Vutuv.Release.purge_blocklisted_screenshots()"`.

Every installation starts with `reddit.com` and `heise.de`, plus whatever
`SCREENSHOT_BLOCKLIST` held when you first migrated. Remove any of them here if
they work fine for you.

## "I didn't do anything!" — the account-activity log

Every security-relevant change to an account is recorded: signing in (and with
which factor), a username rename, an email address added or removed, the
visibility switches, a new passkey or authenticator app, a token minted, a
LinkedIn import applied. Each entry carries the exact time (to the second), the
coarse device summary ("Chrome on macOS"), plus the acting admin when the change
was not the member's own doing. It deliberately keeps **no IP address**: the
member's question is "was that me?", which the device, the time and the
confirming factor answer, and a year of addresses per account is a movement
profile with no support value.

- **Members read their own** at `/settings/activity`, and see the last few
  entries on `/settings/security`. Every row ends in a "Not you?" link back to
  the security page, where they can sign every other device out.
- **You read all of them** at **`/admin` → Account activity**
  (`/admin/activity`): filter by member (name, @handle or email), search over
  device or detail, filter by kind, sort by time, member or kind. This is
  where a support mail that says "my username is different and I did not do
  that" gets answered.

Two things it deliberately does **not** hold, because a log that outlives the
event must be safe to leak: no credential of any kind (no PIN, token, passkey
material, TOTP secret or one-time code), and no private value — an email address
is stored masked (`an***@example.com`), a muted word is recorded only as "a word
or phrase", and a settings save lists the field *names* that were touched, never
what they were set to.

Reading a member's activity is itself recorded, in **your own** log, so opening
this page is as accountable as any other admin action.

Entries age out after a year by default (`ACCOUNT_EVENT_RETENTION_DAYS`), ride
along in the member's data download, and are deleted with the account.

## Honor tags

Besides the tags members give themselves, an admin can define **honor**
tags: badges that only admins grant, e.g. `vutuv_developer` for your
core team. Members can neither add nor remove them, and they are not endorsable.

From the admin panel (`/admin` → Tags):

1. Create the tag (or open an existing one), then **Edit** it and tick
   **Honor**.
2. On the tag's page, use **Add a member (by @handle or email)** to grant it, and
   the per-row **Remove** to take it back. The page lists everyone who holds it.

The badge shows on the member's profile (and its `.md`/`.json`/… siblings) with a
small "honor tag" marker. Reserve honor for **new** tag names: flipping a
tag that members already hold makes them keep it but blocks them from removing it
themselves.

## Being listed in the fediverse directories

Sites like FediDB, the-federation.info and Fediverse Observer keep the public
lists of what runs on the fediverse. They find a server by fetching
`/.well-known/nodeinfo` from it and reading the small JSON document it points
at, so your installation appears on those lists on its own — there is nothing to
submit, and nothing to switch on. If you would rather not be listed, block that
path in nginx.

What the document says about you:

- your name and a sentence or two, from `NODE_NAME` and `NODE_DESCRIPTION`;
- the software and its version (the date of the commit it was built from), so
  a directory can tell vutuv from anything else, plus a link to its source;
- how many members you have, how many of them signed in over the last 30 and
  180 days, and how many public posts and replies they have written;
- the languages you serve, your operator contact (the same one
  `/.well-known/security.txt` already publishes), and links to your
  Nutzungsbedingungen and Datenschutzerklärung — those two only once you have
  actually written them at `/admin/legal`, since a link to a placeholder is
  worse than no link.

Everything in it is an aggregate and nobody is named. The post counts cover
exactly what a logged-out visitor can already read — private, frozen and
unmoderated posts are in neither — and the member figures are the same kind of
number your top bar and your member directory already show. Check yours at
`https://<your host>/system/nodeinfo/2.1`.

**Two claims in the default description are worth understanding before you
publish them under your own name.** "Open source" and "no tracking, no
third-party cookies" are properties of the software: vutuv is MIT-licensed, it
sets exactly one first-party cookie, and its pages load nothing from another
host, so those hold on your installation too. "Hosted on our own hardware in X"
is **not** a property of the software, so it is not in the description string at
all — vutuv appends it from `DATA_LOCATION`, the same variable that drives the
"Where your data lives" card on your start page. Run on rented cloud
infrastructure and you clear that one variable, and the claim disappears from
both places at once rather than being made in your name.

## Federation: blocking a remote server

vutuv can copy a member's public posts to other social websites — independent
servers speaking ActivityPub (Mastodon is the best known), which talk to each
other the way mail servers do. Anyone can run one, so a server that talks to you
is not a vetted party. Your levers live at **`/admin` → Fediverse**
(`/admin/fediverse`); the whole screen is gone on an installation with
`FEDIVERSE_ENABLED=false`.

**Who federates, and what your privacy page has to say.** Each member decides
for themselves, and they are asked twice: the sign-up form carries the question
as a labelled checkbox that is **ticked by default** (with the explanation
beside it, and one click to untick), and `/settings/fediverse` turns it off
again at any time. That single box is the coarse "yes to all of it" and sets
**all three** switches of the settings page — taking part, showing the
reactions that come back, **and showing and storing the replies** people write
on other networks — which is why its text spells the reply storage and its
six-month limit out. So on an installation with `FEDIVERSE_ENABLED=true` expect
most new accounts to federate from their first day, and to hold third-party
replies; nothing leaves the building before the sign-up PIN confirms the
address, and the three switches can be separated again at any time on the
settings page. If holding a stranger's text is not acceptable on your
installation, the only lever today is `FEDIVERSE_ENABLED=false`, which turns
federation off entirely. **Your privacy page has to describe the choice the way
it is actually offered** — presented at registration, pre-selected, covering
reactions and replies, and revocable in the settings. It is per-installation
content, edited at `/admin` → Legal pages, not shipped in the code.

- **Blocklist.** Enter a server name (`mastodon.example` — a full address or an
  `@user@server` handle works too, only the server part is kept). From then on
  everything that server sends is dropped **before** its signature is checked
  and before any of its documents are fetched, and it is answered with a plain
  `202` rather than a refusal, so the list cannot be probed from outside.
  Blocking also **deletes what that server already stored here** (its remote
  followers, the replies its members wrote under your members' posts, its queued
  deliveries) and stops your members' posts from going
  there. Lifting a block later does not bring any of that back — the server has
  to follow again.
- **Caps.** Independent of the list, one remote server may store at most 600
  rows per hour here, and one remote account at most 60. This bounds servers
  nobody has thought to block yet; anything past the budget is dropped for that
  hour. Set `FEDIVERSE_INBOUND_CAPS` to change it (see the configuration table).
- **Inbound volume.** The same page lists what each server has stored here,
  biggest first (followers and stored replies side by side), and the dashboard
  card names the busiest one. That is the list a block decision is made from.
- **Takedowns.** Below it, the replies your members removed or reported. A report
  deletes the reply immediately — there is no queue to work through, because the
  original still sits on the server it was written on and only our copy goes.
  The list is there so you can see a pattern: one account showing up again and
  again, or a whole server doing so, is what the blocklist above is for. It
  deliberately holds **no text and no links**, only which server, which account
  (as a short digest, so repeats are recognizable without keeping the account's
  address), and when — keeping a stranger's words after deleting their reply
  would make the deletion untrue.

**Replies from other networks.** Switched on per member, either by the ticked
Fediverse box at sign-up (which covers all three switches, see above) or on
their own Fediverse settings page, where the switch alone starts off. Once on,
an answer written on another server
under one of their public posts is stored here as **plain text** (never HTML,
and no copy of the author's picture) and shown in the conversation, clearly
marked as coming from elsewhere and linking to the original. A reply addressed
to the member alone is shown only to them.

The retention model, which is what makes holding a stranger's words defensible
at all — they never signed up here and cannot practically be asked:

- A copy is deleted after **six months** at the latest, whatever else happens
  (`FEDIVERSE_NOTE_RETENTION_DAYS`).
- Before that, vutuv asks the origin server now and then whether the reply is
  still published there (`FEDIVERSE_NOTE_REFRESH_DAYS`, and only when somebody
  actually opens the page). Gone or locked away means it is deleted at once,
  usually far earlier than the six months; still there means the text is
  refreshed and the clock starts again, so a reply people keep reading stays in
  step with its original. A server that is simply unreachable changes nothing.
- If the author deletes or edits it on their own server and that reaches us, we
  follow immediately.
- The member can remove any single reply, and switching the setting off deletes
  every one of them.
- Replies sent to a member privately are never re-checked against their origin:
  the answer would be "not found" for anyone but the recipient, and asking would
  tell that server we are holding it.

If you run an installation where holding third-party text is not acceptable at
all, `FEDIVERSE_ENABLED=false` (which turns the whole of federation off) is the
lever — the sign-up box switches replies on along with everything else, so
expect most new accounts to hold them.

**Answering those replies.** A member who takes part in the Fediverse can answer
a **public** reply that came from another network, from the reply's own card in the
conversation. Any member who federates can answer, not only the author of the post
it sits under. The answer is an ordinary public vutuv post that also travels to the
person answered and to the answerer's Fediverse followers, and the page says so
before they write a word, so nobody publishes to another network by accident. A
member who has not switched federation on is shown what the setting does and a
link to it rather than a disabled button.

A reply that was addressed to a member alone cannot be answered: doing it publicly
would publish half of an exchange its author meant for one person.

This is the only case where your installation sends something to a server that
never asked for it, so two things bound it. The target is never freely chosen —
there has to be a stored reply from that server on a vutuv post first, so the
person answered is always somebody who wrote here — and each member has an hourly
budget (`FEDIVERSE_OUTBOUND_REPLY_LIMIT`) as the backstop against a compromised
account being used to relay. Blocking a server at `/admin/fediverse` also stops
answers going to it. Editing or deleting such an answer tells the person answered
too, for as long as the answer exists here — which is why a small delivery address
is kept alongside it even after the six-month copy of their reply is gone.

**Posts with pictures reach other networks a moment later.** A picture is
invisible until image moderation has judged it, so a post carrying one waits for
that verdict before it federates — otherwise the other network would receive the
text and never the picture. Normally that is a few seconds. If the scanner is
down the post keeps waiting, re-checking every `FEDIVERSE_IMAGE_HOLD_SECONDS`
(90), for as long as it takes: nothing travels with a picture the scan has not
cleared, and the queue entry is a database row, so a deploy or a restart does
not lose it. A rejected picture settles the post the same way, and it then
federates without that picture. None of this applies when
`IMAGE_MODERATION_ENABLED` is off.

Readers *here* are not kept waiting meanwhile: a held picture shows as its
pixelated preview (see `IMAGE_PIXELATION_WINDOW_SECONDS`) and swaps itself for the real one
when the verdict lands.

**Followers who leave without saying so.** Somebody on another server who
unfollows, or who deletes their account and whose server announces it, disappears
from a member's follower list at once. Not every departure is announced, so once
an hour vutuv re-asks a small handful of remote servers whether a follower's
account still exists, and drops the row when the server answers "no such account"
(HTTP 404) or "gone" (410). Nothing else drops a follower: a server that is slow,
down, overloaded or rate-limiting you is having a bad day, not losing a person.
Each row is re-asked at most once a month and no more than ten accounts per
server per run, so even a huge server sees a few plain requests an hour. The
nightly report counts the removals ("Entfernte Fediverse-Follower"), which is
where you would notice a whole server dropping out at once. This keeps your
members' follower counts honest and stops the installation from holding the
address of somebody who deleted their account.

**When a member leaves.** Switching the feature off on `/settings/fediverse` does
more than stop sending: from then on the member's Fediverse address answers "gone"
(HTTP 410) instead of "not found", which the common servers read as a deleted
account and take as the cue to delete their copies of that member's posts. Their
remote followers are dropped here at the same time. It stays a request, not a
guarantee, and it applies **only** to a member's own decision to leave: a frozen,
suspended or deactivated account, and an installation you switch off centrally,
keep answering the harmless "not found", so nobody's remote presence is erased
over a temporary measure. Both directions of the switch ask the member to confirm
first, in plain words, because neither can be undone: what has already been
delivered is out of reach, and a member who leaves and comes back may not be
shown again by every server right away.

**When something is taken down here.** Every takedown now asks the other servers
to withdraw their copy, not only a member pressing delete on their own post. A
report that freezes a post asks for its copies to be deleted (and lifting the
freeze publishes the post again); a permanent removal of an account — an admin
ruling, or the third strike on the ladder — tells the servers that follow that
member their account is gone, the same message a real account deletion sends; and
reporting a reply that came from another network passes the report on to that
server's moderators as well as deleting the copy here. Everything **temporary**
deliberately sends nothing at all: a week's suspension or a frozen profile must
never read to the network as "this account was deleted".

None of it is enforceable. Another server can ignore the request, and a request
addressed to a server that is down for a day is retried for about four hours and
then given up on. That is why **`/admin` → Fediverse** ends in a
"Takedowns that did not get through" list: the server, what was asked, and the
last error. A copy on that list is very likely still published somewhere, so it
is worth reading before you tell a member their post is gone — and a server
appearing there again and again is either broken or ignoring you, and can be
blocked on the same page.

**What is stored from other servers.** Exactly one thing: a bare counter row per
remote person per post per kind (favourite / re-share), holding only that
person's account address, the kind and the time. No name, no picture, no text.
Members see the tally as a "reactions from other networks" line under their post
and can switch it off on `/settings/fediverse`, which deletes what is stored. A
row is deleted when the remote side withdraws it, when the post goes, or when
the account goes. **Your installation's privacy page has to say so** — it is
per-installation content, edited at `/admin` → Legal pages, not shipped in the
code.

## Moderation & spam

Members report posts, messages and whole profiles from the quiet "Report"
affordance (category: not family-friendly, bullying, **spam**, other). Reports
land in the admin queue at **`/admin` → Moderation** (`/admin/moderation`); each
new one also emails every admin, and the dashboard tile shows the open count.

On a case you **uphold** (owner gets a strike: warning → suspension →
deactivation), **reject** (unfreezes; can mark a report abusive), or, for
clear-cut spam, use the decisive **remove** buttons:

- **Deactivate account** — hides it site-wide, marks it internally as spam, and
  is **reversible**. Find such accounts later with the **"Removed as spam"**
  filter in the member browser (`/admin/users`) and press **Restore** to bring
  one back if the call was wrong.
- **Delete account** — permanent; erases the account and everything it posted
  (you get the usual deletion record email).

You don't have to catch every spammer by hand: once enough different members
independently report the same profile as **spam**, it is automatically frozen
pending your review. The nightly operator report lists the day's spam
deactivations. A spam mark is never shown publicly.

### When the image scan gets it wrong

A member writes in that their picture was removed for no reason (their mail
lands in your inbox: the removal notice sets a Reply-To to the operator
address). Two ways to see what happened, since the image itself is deleted:

    bin/vutuv eval "Vutuv.Release.image_scan_verdicts()"
    journalctl -u vutuv | grep image_scan

The report prints every recent rejection **and** every suspicion the vote
outvoted, each with the model's own description of the image and how each of
the three opinions fell. That is what you tune against: if harmless pictures
of one kind keep showing up (comics, film stills, Halloween motifs), the
prompt in `Vutuv.Moderation.Ollama` needs a line naming that kind as safe.
The quick lever meanwhile is `IMAGE_SCAN_REJECT_VOTES` / `IMAGE_SCAN_VOTES`
(see the configuration table); a member can always re-upload, since an image
is judged fresh every time.
