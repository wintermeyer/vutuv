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
over members/posts/tags, `Vutuv.Sitemap`), RSS 2.0 feeds with full post content
(`/:slug/posts/feed.xml` per member, `/posts/feed.xml` site-wide,
`VutuvWeb.Feeds`), robots.txt names the AI crawlers and declares draft
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

## Member directory (`/system/members`)

The crawlable A-Z index of every member whose profile is open to search engines
— the same set `/sitemap.xml` advertises (`Vutuv.Directory` owns that one
definition).

An overview of letter tiles with counts plus one page per last-name initial,
paginated at 50 members per page (accents folded, DIN 5007; names without a
letter share an "other" bucket), linked in the footer of every page, so
link-following crawlers and humans reach every indexable profile.

Members with `noindex?` never appear here or in the sitemap, and their profile
answers with the robots meta tag *and* an `X-Robots-Tag` header.

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

Public posts preview as articles with their first line, date and first image
(`/post_images/<token>/og.jpg`, derived on the fly by the authorizing proxy, so
audience changes keep guarding it); restricted posts and teasers never leak the
body or an image.

The **description** falls through a chain (`OpenGraph.description/1`): a page's
own `:meta_description` assign (a controller render assign or a LiveView socket
assign — the CV builder and the tag page set one), else a public post's first
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
