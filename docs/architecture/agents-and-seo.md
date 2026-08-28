# Agent formats & SEO

Machines are first-class readers of vutuv: every public page has agent-format
siblings, crawl signals honor two independent member choices, and previews /
structured data derive from single chokepoints.

## Agent formats (markdown for agents)

Every public page is also served as **Markdown**, **plain text** (80 columns),
**JSON** and **XML** under the same URL plus an extension —
`/stefan.wintermeyer.md` / `.txt` / `.json` / `.xml`, the profile additionally
as `.vcf` (vCard 3.0) — or via `Accept: text/markdown` / `text/plain` /
`application/json` / `application/xml` content negotiation (the Cloudflare
"markdown for agents" convention).

Covered pages: profile, post permalinks, the post archive, follower/following
lists, tag pages, the most-followed listing and the member directory;
`/llms.txt` documents the scheme.

An **"Other formats" card** surfaces these links on the profile aside, the post
permalink and the feed rail.

Labels default to English (the canonical, cache-safe rendering — the session
locale is deliberately ignored); `?lang=de` opts into a translated rendering,
and the card links it for visitors browsing in German.

These variants render the **anonymous public view** from one doc map per page
(`VutuvWeb.AgentDocs.*Doc` — the single source of truth; a drift test fails when
a page's HTML and its docs diverge).

The **newsfeed** is the one exception: `/feed.md/.txt/.json/.xml`
(`VutuvWeb.AgentDocs.FeedDoc`, negotiated by `VutuvWeb.NewsfeedController` — the
controller in front of the `/feed` LiveView) render the signed-in viewer's own
timeline, so they are login-only and sent `private, no-store` + `noindex/noai`
(an agent-format request without a session 404s, and a feed has no `.vcf`).

Documents carry `schema_version` + `generated_at`; responses carry
`Content-Signal`, `Vary: Accept` and `x-markdown-tokens`.

The signals render **two independent member choices**
(`VutuvWeb.ContentPolicy`), both asked at sign-up and editable on the profile
form: `noindex?` (search engines → `search=`, robots `noindex`) and `noai?` (AI
agents/LLMs → `ai-train=`/`ai-input=`, robots `noai, noimageai`) — any
combination is valid; pages that are noindexed page-level (profile sections,
people lists, restricted posts) send every signal as `no`.

The per-user detail sub-pages (`/:slug/emails`, `/tags`, `/work_experiences`,
`/followers`, …) are kept out of search by that page-level `X-Robots-Tag:
noindex` (`VutuvWeb.Plug.NoIndex` on the `:user_pipe` pipeline), **not** by a
`robots.txt` `Disallow`. This is deliberate: a `Disallow` only stops the fetch,
so a detail URL linked from elsewhere is still indexed as a bare link and can
never be crawled to learn it should drop out — which is exactly how these URLs
piled up under Google's "indexed, though blocked by robots.txt" report. For the
same reason the legacy `/users/…` URLs (which 301 to the canonical `/:slug`)
stay crawlable: blocking a redirect strands the old URL instead of letting the
301 consolidate it. So `robots.txt` blocks only `/admin/`.

The **tag host** (`tags.<our host>`, issue #1330) is the same reasoning applied
to a whole hostname. It carries topic actors and nothing anybody reads, so none
of it should ever appear in a result — and the way there is not `Disallow: /`,
which would strand whatever is already indexed, but the pair this section
describes: every response it gives carries `X-Robots-Tag: noindex, noai,
noimageai` (the `:tag_host_docs` pipeline, and `VutuvWeb.Plug.TagHost` for the
redirects), and its own short robots.txt (`VutuvWeb.RobotsTxt.tag_host/0`)
disallows nothing so that header can be read. A page asked for there is
redirected to the same page on the apex, which is the stronger signal of the
two: a 301 consolidates the URL rather than merely dropping it.

Everything else resolves itself and is deliberately crawlable too, because any
`Disallow` beyond `/admin/` kept re-filling that Search Console bucket (and a
failed "validate fix" pass there emails the operator):

- `/login` and `/search` serve `X-Robots-Tag: noindex` via the `:noindex_pipe`
  in the router. `/login` matters doubly: it is the redirect target of every
  login-only URL a crawler stumbles into (`/posts/:id/reply`, `/messages`, …),
  so it must be fetchable for those chains to resolve. The reply links on
  post cards additionally carry `rel="nofollow"`, so the per-post reply URLs
  rarely enter the crawl frontier at all.
- The RSS feeds (`/posts/feed.xml`, `/:slug/posts/feed.xml`) are always
  `noindex` — Google filed a permissive member's feed as a "duplicate without
  a user-selected canonical" of their profile.
- `/sessions/new` is a 301 to `/login`; the pre-2026 API vCard URLs
  (`/api/1.0/users/:slug/vcard`) 301 to `/:slug.vcf`
  (`VutuvWeb.LegacyRedirectController`). Redirects must be crawlable.
- The rest of `/api/` answers crawlers itself: 404 for retired 1.0 paths,
  401 for the token-only 2.0 endpoints; nothing links it, nothing indexes it.
- `GET /logout` does not exist (signing out is a `DELETE`), so a `Disallow`
  for it fenced off nothing.

Existing members were migrated as AI-opted-out (they were never asked) and can
opt in on the edit form.

A single opt-out is also embedded in every document body (`noindex`/`noai` in
the JSON/XML fields, the Markdown frontmatter and the text footer), and a member
who opted out of **both** search and AI serves no profile agent documents at
all: their profile-namespace `.md`/`.txt`/`.json`/`.xml` URLs answer 404
(`VutuvWeb.Plug.AgentExportOptOut`), the page advertises no alternates, and the
"Other formats" card shows a short note instead (the human-oriented vCard
stays).

The extension parsing lives in `VutuvWeb.Plug.AgentFormat` (endpoint; only the
five known extensions are stripped, so dotted slugs keep working, and a `.md`
URL that no controller answers 404s instead of serving HTML).

**Agent readiness** (per specification.website): `/sitemap.xml` (chunked index
over members/posts/tags, `Vutuv.Sitemap`; tag pages appear only above the
search-engine bar — `Vutuv.Tags.indexable_tags_query/0`: at least
`min_indexable_members/0` visible members or one public post. Every tag page
below the bar answers with `X-Robots-Tag: noindex` from `TagController`, so
the ~10K thin one-member/empty tag pages stopped piling up in Search Console
as "crawled - currently not indexed"), RSS 2.0 feeds with full post content
(`/:slug/posts/feed.xml` per member, `/posts/feed.xml` site-wide,
`VutuvWeb.Feeds`; an author feed (a member's or a page's) carries the newest
**100** posts, the site-wide firehose the newest 20, since an archive somebody
subscribed to owes them more history than a firehose everyone polls; the member feed carries **original posts only** — reposts
are engagement rows and never `Post` rows, and replies are filtered by the
archive's `:posts` predicate in `Vutuv.Posts.recent_public_posts/2` — while
the site-wide firehose deliberately keeps replies; besides the invisible
`<link rel="alternate">` autodiscovery there are three visible ways in, all
pointing at the same canonical `/:slug/posts/feed.xml`: the profile's
**Subscribe card** at the foot of the page, which pairs the feed (the
`<.feed_button>` pill plus the absolute URL as a copy target) with the
member's Fediverse address and is signed from the Posts card header by a
`<.subscribe_link>` anchor; the `<.feed_button>` pill in the `/:slug/posts`
archive header; and the "Other formats" card's RSS chip (`rss_path` attr),
which is the one that still serves on a profile whose Posts card does not
render at all. (Issue #1287 first moved the pill out of that chip and into
the Posts card header, because a card at the foot of a long profile was
reported as "no feed button"; the header sign is what keeps that fixed now
that the pill itself sits in a card again, this time in one named after
what the reader wants.) `/:slug/posts.xml` — the
URL readers guess for "posts as XML" — 301s to the member feed instead of
serving the generic `<post_archive>` agent document, which a feed validator
rejects; the period-scoped archives keep their XML sibling), robots.txt names the AI
crawlers and declares draft
`Content-Signal` directives from the one policy source
(`VutuvWeb.ContentPolicy`, config `:ai_crawler_policy` — flips robots.txt and
the response headers together), `Link` headers advertise
llms.txt/sitemap/per-page alternates (`VutuvWeb.Plug.AgentLinks`), schema.org
JSON-LD (Person on profiles, BlogPosting on permalinks, WebSite+SearchAction on
the homepage — `VutuvWeb.JsonLd`, drift-tested against the doc builders), and
`/.well-known/` serves agent-skills discovery (Cloudflare draft, digest-verified
`SKILL.md`) plus `security.txt`

## Profile SEO (`/:slug` and its subpages)

The profile page is the SEO priority; its head is built to rank for the
member's name (and name + role queries):

- **Title**: `Full Name · <work line>` (or the headline when there is no
  current job), derived in `VutuvWeb.LayoutHTML.page_title/1` from the same
  `:header_job` the profile header shows; `og:title` shares it. A member with
  neither keeps the bare name.
- **ProfilePage JSON-LD** (`VutuvWeb.JsonLd.person/5`) carries the fields
  search engines document for profile pages: `dateCreated`/`dateModified`
  (account timestamps), `alternateName`/`identifier` (the handle),
  `interactionStatistic` (followers as a FollowAction counter),
  `agentInteractionStatistic` (posts as a WriteAction counter) — plus the
  Person entity enriched from what the page already loaded (accuracy rule,
  no extra queries): `description` (plain-text headline), `alumniOf`
  (educations), `knowsLanguage`, `hasCredential` (qualifications),
  `address` (public addresses), and `sameAs` = social accounts + **verified**
  profile links (`Vutuv.Profiles.LinkVerification`). A `noindex?` member
  still gets no Person block.
- **`profile:*` Open Graph tags** (first/last name, username) on every
  member page that is not a post.
- **Every public subpage titles itself** `Full Name · <Section>` (entry
  pages use the entry: job title, school, tag name, …) via
  `UserHelpers.member_page_title/2` — before this they all fell back to the
  member's bare name and competed with `/:slug` for the same title
  (`profile_subpage_titles_test.exs` enforces name + uniqueness). New public
  member subpages must set such a `:page_title`.
- **BreadcrumbList JSON-LD** rides `<.page_header>` wherever a visible
  crumbs trail renders (`JsonLd.breadcrumb_trail/1`), so section pages show
  their place under the profile in search results.

Deliberately *not* done: profile subpages stay out of the sitemap (they are
near-duplicates of the profile's own cards; internal links and unique titles
are the right treatment), and locale stays Accept-Language-negotiated on one
URL (no hreflang variants).

## Reading Search Console

Google's index reports lag the site by weeks, so a red bucket here is normally
Google catching up with a fix that already shipped, not a defect. What each one
means for this installation, re-checked against production on 2026-08-10:

- **"Indexed, though blocked by robots.txt"** holds legacy `/users/…` URLs
  only, every one last crawled before the robots.txt fixes above. Nothing on
  the site can add to it: robots.txt fences `/admin/` and nothing else,
  `/users/:slug` 301s to the canonical `/:slug`, and `/login` answers 200 with
  `X-Robots-Tag: noindex`. The important part is how validation behaves: a
  "validate fix" pass **fails on the first URL whose last crawl still saw the
  old state**, so it can go red long after the cause is gone. The July pass
  failed on `/login` alone, crawled three days before v7.185.1 freed it.
  Restarted 2026-08-10; Google takes weeks over such a run.
- **"Crawled - currently not indexed"** is dominated by the profiles'
  `.md`/`.txt`/`.json`/`.xml` siblings, and for them this bucket is the
  *correct* end state, not a backlog: each answers with
  `Link: <…>; rel="canonical"; type="text/html"`, so Google fetches the
  document, learns the content belongs to the HTML page and files it here.
  Leave it alone, and in particular never put `noindex` on those URLs: a
  canonical says "index the other one", a noindex says "index neither", and a
  page carrying both gives Google contradictory instructions. (The ~10K thin
  tag pages that used to fill this bucket are a separate, solved story: the
  indexability bar above.)
- **The 404 and 403 buckets are intended** (agent-export opt-out, moderation
  withholding), as documented above.
- **The "Profile page" rich-result report can read 0 valid items with nothing
  broken.** It counts freshly crawled pages, so at this crawl volume it drops
  to zero on its own. Live, every indexable profile serves the full JSON-LD
  (verified 2026-08-10: ProfilePage, Person, Organization, BreadcrumbList).
  Check a real 200 profile before believing a regression, and mind the trap
  that makes the check itself lie: a *guessed* handle 404s with a
  fully-styled error page whose head carries a self-canonical, which reads
  like a profile page with its structured data stripped out.
- **Sitemap, HTTPS and breadcrumbs are green.** Core Web Vitals reports no
  data, which is what too few CrUX samples look like at the current traffic,
  not a measurement failure.

The standing rule behind all of it: verify the live response before treating a
Search Console bucket as a bug (`curl -sI`, the JSON-LD in the rendered page),
because every report here describes the site as it was at the last crawl.

## Member directory (`/system/members`)

The browsable A-Z index of **every** listed member, and the crawl surface for
search engines that follow links rather than reading `/sitemap.xml`.

An overview of letter tiles with counts plus one page per last-name initial,
paginated at 50 members per page (accents folded, DIN 5007; names without a
letter share an "other" bucket), linked in the footer of every page, so
link-following crawlers and humans reach every profile.

`Vutuv.Directory` holds two member sets apart, and the difference is the point.
`listed_users/0` — confirmed, not moderation-hidden — is what the directory
shows. `indexable_users/0` is that set minus the search-engine opt-out
(`noindex?`), and it is what `/sitemap.xml` advertises. Until v7.407.0 the
directory used the second for both, so a member who had opted out of search
engines was missing from the one page whose job is to help somebody find them —
while `/search`, the most-followed listing and every follower list had listed
them all along. The directory was the outlier, not the rule.

What the opt-out buys now is `rel="nofollow"` on that member's row
(`UserHelpers.profile_rel/1`, applied in the shared `card_list` and `user_row`
and in the two public member lists that build their own rows, `/:slug/connections`
and `/:slug/tags/:id/endorsers`) plus their absence from the sitemap and the
`X-Robots-Tag: noindex` their profile already answers with. `noindex?` rides in
`User.listing_fields/0` so a listing row can decide its own `rel` without a
second query — left out, the struct would carry the schema default `false` and
the link would fail *open*.

### The search box

`VutuvWeb.DirectorySearchLive`, embedded into the overview with `live_render`
so `DirectoryController` keeps owning the agent-format siblings. A **field**
search rather than the free-text page at `/search`: a case-insensitive
substring in first name, last name and username, OR-ed across whichever of the
three checkboxes are ticked, with every word of a multi-word query having to
match some ticked field ("anna mei" and "mei anna" both find Anna Meier).

All three boxes start ticked and unticking the last one ticks all three again —
one rule, `Directory.parse_search_fields/1`, applied on every path. Keeping the
previous selection instead cannot be rendered: `@fields` would not change, so
the diff would carry nothing for that checkbox and it would stay visibly
unticked while the server searched as though it were on.

A large result set is revealed in bites of `results_step/0` (25) up to
`results_ceiling/0` (the site-wide page maximum), with the total stated first;
past the ceiling the box asks for a narrower query rather than offering another
press. A pager would be the wrong control here — the next keystroke invalidates
whichever page you walked to.

Being off-router it cannot `push_patch`, so the box is a real GET form at
`/system/members`: keystrokes patch results over the socket, Enter lands on a
shareable `?q=` URL whose dead render shows the same results, and "show more"
is a `?show=` link until the socket connects. A `?q=` page is stamped
`noindex` — search results are the hall of mirrors `/search` is noindexed for,
and here they would additionally publish the names of members who asked to stay
out of search results. The bare overview stays indexable.

The minimum is three characters, and that number is not arbitrary: pg_trgm
needs three to form a trigram, so a shorter needle plans a sequential scan of
`users` whatever indexes exist. `20260828083124_add_users_name_trigram_indexes`
adds the GIN trigram indexes on the three columns, and the total rides along on
the rows as a window count rather than as a second `Repo.aggregate/2` — one walk
of the match set instead of two, on a query a member re-runs at every keystroke.

A letter page files each row under the name it is sorted by ("Özil, Mesut",
`UserHelpers.filed_name/1`, switched on by the `filed_names` assign the
directory alone passes to the shared `card_list`); a column of "Vorname
Nachname" under a heading of "M" leaves the reader scanning for the word the
order is built on. The avatar's alt text and the agent docs keep the canonical
name, so only the visible listing changes.

The overview prints **no figure at all** — not the total, and not a count under
any letter tile. It went in two steps, both Stefan's: it briefly printed three
(the listed count, the whole membership and the Fediverse head count), lost the
last two on 2026-08-13 because they belong to the top bar's people pill which is
on this page like every other, and lost the listed count and the per-letter
counts on 2026-08-28. A page whose job is an A-Z index reads as a statistics
page the moment it opens with numbers. A tile still says what a browsing reader
needs by being a link or a muted square; the figure survives as `data-count`,
which is invisible and what the tests read.

The counts stay in the **agent formats** — `total` plus a per-letter `count`,
and the `.md`/`.txt` renderings print `a (226)` per line — because a machine
reader has no A-Z strip in front of them and a count is what they came for.
That asymmetry is the point of having two renderings, not drift between them,
so the drift test asserts the numberless sentence appears everywhere *and* that
the structured counts are present. Those siblings answer for the directory
itself and never for a `?q=`: a doc that changed under a query would make the
canonical URL name a different document every time.

It lives under `/system/` — the one reserved word all future site pages share,
so new pages stop burning root path words members could have as handles.

## Link previews (Open Graph)

Every HTML page carries `og:*` + `twitter:card` tags derived in one chokepoint
(`VutuvWeb.OpenGraph`, rendered by the root layout; the plain description meta
shares the same derivation).

Pages about a member preview their name, work info and avatar — served as a
scraper-friendly square JPEG at `/:slug/avatar.jpg`
(`VutuvWeb.AvatarController`; preview scrapers don't decode the site's AVIF),
derived on the fly from the kept original, metadata-stripped.

Public posts preview as articles with their teaser line, date and first image
(`/post_images/<token>/og.jpg`, derived on the fly by the authorizing proxy, so
audience changes keep guarding it); restricted posts and teasers never leak the
body or an image.

**One module decides which line that is.** `VutuvWeb.PostTeaser.line/2` — and
its flattened twin `plain_line/2` — is the single owner of the app's one-line
post teaser, read by the Open Graph description below, the RSS
`<description>`, every doc builder that lists posts rather than rendering one,
a search result, an organization's activity list, the /notifications
breadcrumb, the daily report and the feed's tab ticker. It is the post's first
line, minus the openers a reader learns nothing from: a quote post's
`RE: <url>` reference to the status it quotes (Mastodon writes one, and it
names that status by id), and a line with no words in it (a `---` rule, a lone
code fence, a line of nothing but inline images). Both functions pick the
**same** line, so no two of those surfaces can quote one post differently. The
next exception goes in that module's `@skippable`, never at a call site. Which
column a post keeps its text in is `Vutuv.Posts.text/1`, beside `author/1` and
`path/1`.

The **description** falls through a chain (`OpenGraph.description/1`): a page's
own `:meta_description` assign (a controller render assign or a LiveView socket
assign — the CV builder and the tag page set one), else a public post's teaser
line, else a member's work info, else a **per-page description** keyed on the
request path (`page_copy/1`: the settings sections, the `/system` directory, and
the public info pages — login, community, legal, developers, the tags and
most-followed listings), else the generic site pitch (a business network, free
to join). The path lookup reads `conn.request_path`, which is present in both a
dead controller render and the disconnected LiveView render, so it works
everywhere the tags render. The `/settings/*` pages redirect a logged-out
link-preview bot to the landing page (`RequireLogin`), so their copy is really
for signed-in shares; the description they carry is still honest per page. New
strings are gettext-translated (German included), so a German share previews in
German.

Everything else falls back to `/og-card.png` (`VutuvWeb.OgCard`): the white
wordmark (shipped pre-rasterized as a PNG) composed onto the brand gradient,
generated once per node (no font or SVG-loader dependency, so it renders
identically in dev, test, CI and production).
