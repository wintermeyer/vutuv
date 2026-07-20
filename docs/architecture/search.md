# Search

The **Search** page (`/search`) is a LiveView, part of the shared
`live_session` (see [realtime.md](realtime.md)).

## The search page

Search is search-as-you-type (results from three letters on, exact and
similar-sounding name matches clearly separated, `?q=` plus the filters keeps
the URL shareable and a settled query is recorded once) with scope chips
(all/people/tags/posts), an exact-only toggle and query operators parsed by
`Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aka `first:`/`last:`),
`@handle`, double quotes for exact, the combinable filter `tag:`/`skill:`
(has the tag) which finds **both people and posts** carrying it (issue #946),
plus the combinable people-only filters `ort:`/`stadt:`/`city:` (address in
that city) and `status:looking` / `status:open` (job-availability, #928 —
honored only for a signed-in viewer, logged-out search ignores it and a
`hidden` status never matches), e.g. `müller tag:php`, `müller ort:koblenz` or
`elixir status:open`. Only the people-only operators pin the scope to people
(`scope_pinned?`); `tag:` leaves the scope free, so its chips still narrow to
just people or just posts.

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
