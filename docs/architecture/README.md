# vutuv architecture

How the vutuv codebase is put together, one document per subsystem, plus the
stack conventions and the context-module map below.

Setup, tests and deployment live in [Developing vutuv](../DEVELOPERS.md);
installing and operating vutuv in [Running your own vutuv](../ADMINS.md).

## Subsystem documents

| Document | Covers |
|---|---|
| [realtime.md](realtime.md) | the LiveView app shell, live pages, reload-free updates over PubSub, presence & online dots, notifications, Berlin-time post stamps, the live member counter |
| [social-graph.md](social-graph.md) | follows, vernetzt (mutual follows), per-follow mute, blocking |
| [fediverse.md](fediverse.md) | follow-only ActivityPub federation: WebFinger, actors, the inbox, signed deliveries |
| [posts-and-feed.md](posts-and-feed.md) | posts, deny-based audiences, the `/feed` timeline, likes/bookmarks/reposts, reply threads, post images |
| [search.md](search.md) | the search page, query operators, post full-text search |
| [messages.md](messages.md) | 1:1 direct messages, message requests, unread-email nudges |
| [invitations.md](invitations.md) | invite a non-member: hashed once-per-address record, prefilled sign-up link, per-inviter daily cap, auto-follow |
| [profiles.md](profiles.md) | what a profile shows: owner vs. public view, the job-title line, education, section ordering, contact details & maps, the Mastodon/Bluesky card |
| [companies.md](companies.md) | verified company pages at `/companies`: the domain-proof trust model (DNS TXT / well-known file), lifecycle states, engagement, moderation, agent formats |
| [settings-and-account.md](settings-and-account.md) | the settings hub, onboarding, username changes, LinkedIn import, GDPR export, the CV (Lebenslauf) download |
| [authentication.md](authentication.md) | passwordless PIN login, passkeys, server-side sessions |
| [moderation.md](moderation.md) | reports, freezes, the strike ladder, reporter trust, evidence screenshots |
| [agents-and-seo.md](agents-and-seo.md) | agent formats (`.md`/`.txt`/`.json`/`.xml`/`.vcf`), the member directory, sitemap/RSS/JSON-LD, Open Graph |
| [email.md](email.md) | the Emailer chokepoint, multipart bodies, opt-outs, bounces & deliverability |
| [images.md](images.md) | the AVIF pipeline, kept originals, fingerprinted filenames, URL screenshots |
| [admin.md](admin.md) | the admin panel: live dashboard, member browser, account deletion, newsletter & audiences, daily report |
| [ads.md](ads.md) | the daily text ad: booking, review, serving |
| [api.md](api.md) | `/api/2.0`: personal access tokens, OAuth 2, webhooks, developer docs |

## The stack

- **Views**: mostly Phoenix 1.8 HTML modules with `embed_templates` (no
  `phoenix_view` dependency); **LiveView is being adopted incrementally** for
  the real-time parts (see [realtime.md](realtime.md))
- **Routes**: Verified routes (`~p"..."` sigils). Profiles live at the URL root,
  GitHub-style: `/:slug` is the profile and all per-user sub-pages hang off it
  (`/:slug/links`, `/:slug/followers`, `/:slug/following`, `/:slug/connections`,
  ...). The legacy `/users/:slug/...` URLs, `/sessions/new` and
  `/search_queries/...` 301 to their new homes (`/login`, `/logout`, `/search`).
  The user scope is the **last** in the router, so static routes always win;
  `Vutuv.Accounts.ReservedSlugs` keeps users from registering a slug that equals
  a route prefix. The URL-root namespace is **shared** with companies: a company
  can claim a member-style `@handle` and serve at `/:handle` too, with global
  uniqueness guaranteed by the `handles` registry table (see
  [companies.md](companies.md), #941). The old read-only `/api/1.0` JSON API was
  removed in favor of `/api/2.0`; only the session-aware vCard survived, at
  `/:slug/vcard`
- **Forms**: `<.form>` component with `<.inputs_for>` for nested forms
- **Assets**: esbuild + Tailwind CSS v4; dark mode follows the system
  (`prefers-color-scheme`, no toggle) — legacy pages get their dark styles
  centrally from `assets/css/components.css`
- **HTTP server**: Bandit
- **Pagination**: browse pages (followers, tags, the admin member browser) use
  offset pagination — `Vutuv.Pages.paginate/3` on the query plus the `<.pager>`
  component for the numbered links; feed LiveViews (notifications) use cursor
  pagination instead — `Vutuv.Activity.notifications_page/2` behind a numbered
  "Load 50 of 80 more" button that appends to the stream. Displayed counts
  (badges, follower numbers) are compacted site-wide via
  `VutuvWeb.UI.compact_count/1`: exact up to 999, then 1K/80K/5M. The one
  exception is the landing-page member counter, which shows the **exact** total
  via `delimited_count/1` (see [realtime.md](realtime.md))
- **Ids**: all database ids are UUID v7 (`Vutuv.UUIDv7`): time-ordered, minted
  in the app, never integers or UUID v4.

## Context modules

Business logic is organized into Phoenix context modules under `lib/vutuv/`:

| Context | Schemas | Purpose |
|---|---|---|
| `Vutuv.Accounts` | User, Email, UsernameChange, SearchTerm, LoginPin, Locale, Exonym | Registration, PIN-based authentication, user management |
| `Vutuv.Sessions` | UserSession | Server-side per-device sessions: signed-in-devices list, remote logout, new-device security email |
| `Vutuv.Credentials` | UserCredential | Passkeys (WebAuthn/FIDO2): enrolment + assertion verification for passkey login |
| `Vutuv.ApiAuth` | Token, App, Grant, AuthCode | API credentials: personal access tokens, OAuth 2 apps/grants/codes, scopes |
| `Vutuv.Webhooks` | Subscription, Delivery | Signed webhook deliveries to registered apps (queue, backoff, kill switch) |
| `Vutuv.Profiles` | Address, PhoneNumber, SocialMediaAccount, Url, WorkExperience | User profile data |
| `Vutuv.Social` | Follow, Block, Group, Membership, UserLike, UserBookmark | Follows (a mutual follow = vernetzt), per-follow mute, blocking, groups, liking/bookmarking people |
| `Vutuv.Posts` | Post, PostDenial, PostImage, PostTag, PostLike, PostBookmark, PostRepost, PostReply | Posts, deny-model audiences, the feed, likes/bookmarks/reposts, replies/threads |
| `Vutuv.Tags` | Tag, UserTag, UserTagEndorsement | Tagging and endorsements |
| `Vutuv.Search` | SearchQuery, SearchQueryRequester, SearchQueryResult | Search functionality (people/tags; post full-text via `Vutuv.Posts.search_public/2`) |
| `Vutuv.Chat` | Conversation, Participant, Message | 1:1 direct messages, message requests, unread email notifier |
| `Vutuv.Moderation` | Case, Report, Strike | Reports, the content freezer, the strike ladder, reporter trust |
| `Vutuv.Notifications` | Emailer | Email notifications |
| `Vutuv.Newsletters` | Newsletter, NewsletterDelivery, NewsletterClick, NewsletterGroup, NewsletterGroupMember, Markdown | Admin email newsletter ("Rundbrief"): draft, test send, broadcast, delivery log, link click tracking + success overview, and filter-built audience groups |
| `Vutuv.Deliverability` | Event, MailLog, Watcher, Sweeper | Bounce detection: deactivate dead addresses, freeze unreachable accounts, admin dashboard |
| `Vutuv.Ads` | Ad | The daily text ad: booking, billing record, serving |
