# Search

The **Search** page (`/search`) is a LiveView, part of the shared
`live_session` (see [realtime.md](realtime.md)).

## The search page

Search is search-as-you-type (results from three letters on, exact and
similar-sounding name matches clearly separated, `?q=` plus the filters keeps
the URL shareable and a settled query is recorded once) with scope chips
(all/people/tags/posts), an exact-only toggle and query operators parsed by
`Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aka `first:`/`last:`),
`@handle`, double quotes for exact, plus the combinable people filters
`tag:`/`skill:` (has the tag) and `ort:`/`stadt:`/`city:` (address in that
city), e.g. `müller tag:php` or `müller ort:koblenz`.

## Post search

The search page also finds words in **fully public** posts via Postgres
full-text search (`Vutuv.Posts.search_public/2`); how audiences keep restricted
posts out of the results is covered in [posts-and-feed.md](posts-and-feed.md).
