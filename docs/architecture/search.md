# Search

The **Search** page (`/search`) is a LiveView, part of the shared
`live_session` (see [realtime.md](realtime.md)).

## The search page

Search is search-as-you-type (results from three letters on, exact and
similar-sounding name matches clearly separated, `?q=` plus the filters keeps
the URL shareable) with scope chips (all/people/tags/posts), an exact-only
toggle and query operators parsed by `Vutuv.Search.parse/2`:
`vorname:`/`nachname:` (aka `first:`/`last:`),
`@handle`, double quotes for exact, the combinable filter `tag:`/`skill:`
(has the tag) which finds **both people and posts** carrying it (issue #946),
plus the combinable people-only filters `ort:`/`stadt:`/`city:` (address in
that city) and `status:looking` / `status:open` (job-availability, #928 —
honored only for a signed-in viewer, logged-out search ignores it and a
`hidden` status never matches), e.g. `müller tag:php`, `müller ort:koblenz` or
`elixir status:open`. Only the people-only operators pin the scope to people
(`scope_pinned?`); `tag:` leaves the scope free, so its chips still narrow to
just people or just posts.

## Nothing about a query is stored

A search is answered and forgotten. Until v7.306.0 every settled query was
written to `search_queries` / `search_query_results` /
`search_query_requesters` (the query string, the members it matched, and who
searched it), and a daily sweeper pruned it to 90 days. No feature ever read a
row of it: the phonetic matcher behind it (`Search.search/2`) existed only to
fill the result table, and the privacy policy justified the whole thing with a
search it would "improve and speed up" that was never built. All of it is gone;
the tables are dropped in the next deploy (expand/contract).

The one thing that IS derived from member data is `search_terms`, the name
index: `Accounts.SearchTerm.create_search_terms/1` writes eighteen rows per
member, six combinations of first and last name, each in plain form and in its
Cologne-phonetics and Soundex encodings. Substring matching runs against the
plain rows, "sounds like" against the encoded ones. It is by far the largest
table in the database (21 MB of a 75 MB production database at ~6,000 members)
and worth revisiting if membership grows by an order of magnitude; the
replacement would be encoded columns on `users` plus a trigram index, not a
second table.

## Saved searches (issue #935)

A signed-in member can save the current people search as a `SavedSearch`
(kind `people`) from the quiet "Save search" control that appears once the
query carries a structured operator (`tag:`/`ort:`/`status:`). The stored
`query` is the same `/search` URL query string, so the "run now" link and the
nightly alert sweeper replay the identical search. Alerts, matching and the
digest e-mail live with the job board — see
[jobs.md](jobs.md#saved-searches-and-alerts) — because both sides of the market
share one `Vutuv.SavedSearches` context and one `AlertSweeper`. People matching
(`Vutuv.Search.new_matching_people/3`) only ever surfaces members the recipient
could see logged in (base #928 visibility plus the #938 per-viewer exclusion for
status searches) and never leaks a member's private salary expectation.

## Post search

The search page also finds words in **fully public** posts via Postgres
full-text search (`Vutuv.Posts.search_public/2`); how audiences keep restricted
posts out of the results is covered in [posts-and-feed.md](posts-and-feed.md).
A `tag:` filter narrows the same `search_public/2` to posts carrying that tag
(an `EXISTS` over `post_tags`, name/slug match), and a bare `tag:php` with no
body words is a pure tag listing (newest first) — the post twin of the tag
page's "Posts with this tag" section (`Vutuv.Posts.list_tag_posts/3`, issue
#946), which lists the public posts filed under a tag so a tag used only in
posts no longer opens an empty page. The tag page offset-paginates those posts
with the numbered `<.pager>` (`?page`, like the tag index); its front matter
(description, most-endorsed members, jobs) rides only on page 1.

## What is pasted here but is not a query

Two things people put in the box are addresses rather than words, and no amount
of full-text search will ever match either. Both are recognised by **pure string
work** in `SearchLive` — a keystroke must never become an outbound request — and
both render as a card **above** the results, because they are the answer to what
was pasted:

* an **account address** (`@name@server`, or a profile URL, issue #1160):
  `#search-remote-address` names it and hands it to the follow box at
  `/settings/fediverse/following?address=`.
* the address of a **single post** out there (issue #1211):
  `#search-remote-post` offers the fetch that used to live only at
  `/system/fediverse/lookup` — a page under `/system/` that nobody finds, while
  the address they want to look up is already in their clipboard and a search
  box is in front of them. Pressing Enter on it does the same as the card's
  button, since a submit means "get me that"; `phx-change` deliberately does
  not, or typing a URL out by hand would fetch every prefix of it.

The two are told apart the way `Vutuv.Fediverse.look_up_post/2` tells them
apart — `RemoteFollow.parse_address/1` accepts exactly `@you@server`,
`you@server` and `https://server/@you`, and a post URL has one path segment too
many for all three — and **our own** addresses are excluded from both by
`Fediverse.own_host?/1`, `www.` alias included.

The fetch itself is `look_up_post/2` unchanged: signed in the member's name,
metered against their hourly `FEDIVERSE_LOOKUP_LIMIT`, free for a post already
cached here. So the card never fetches on render; it waits for the click or the
submit, and a member who cannot sign such a request (they do not federate, they
moved away) reads why, plus the switch, from the one wording table in
`VutuvWeb.FediverseComponents` that the lookup page reads too. A resolved post
does **not** get a second result view here: the reader is sent to our copy's own
page at `/system/fediverse/post/:id`, the one every remote card's timestamp
points at, which already carries the action bar, the ⋯ menu and the way on to
the account.

The search tips list both, and only where they apply: the account row under
`all`/`people`, the post row under `all`/`posts`, and neither on an installation
with the Fediverse switched off, where both cards are unreachable. The
placeholder names the address too, since that is the help a member reads before
typing.
