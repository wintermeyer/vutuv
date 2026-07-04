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

Everything else falls back to `/og-card.png` (`VutuvWeb.OgCard`): the white
wordmark (shipped pre-rasterized as a PNG) composed onto the brand gradient,
generated once per node (no font or SVG-loader dependency, so it renders
identically in dev, test, CI and production).
