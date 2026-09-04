# Company pages and the footer

The footer, the two English company pages it links to (`/system/investors` and
`/system/media-kit`), and the daily head-count history the investor page draws
as a growth curve.

## The footer

`lib/vutuv_web/templates/layout/app.html.heex`, so it is on every page, dead and
live alike.

It is four labelled groups plus a credit bar. Before that it was one row of
links separated by middots, which had grown to ten entries and read as a wall of
words: nothing said where a new link belonged, so each one went on the end.

| Group | Holds |
|---|---|
| Network | member directory, organizations, jobs |
| Developers | API documentation, source, bug/feature reports |
| Company | Investors, Media Kit, advertising, Impressum |
| Legal | privacy policy, terms, community guidelines |

Two columns on a phone, four from `md` up, each group a vertical list. The
vertical list is the mobile-first choice, not the desktop one: in a dotted run
every link is a word inside a paragraph, and here each is a `py-2` row that a
thumb can hit.

The credit bar underneath carries the operator on the left and what is running
on the right (the commit it runs and when that was made, `Vutuv.BuildInfo`). The
operator half reads the identity in `config/config.exs`, the commit link the
`:source_url`, so a third-party installation credits itself.

## The two company pages

`VutuvWeb.CompanyController`, rendered by `VutuvWeb.CompanyHTML`, with
`VutuvWeb.AgentDocs.InvestorsDoc` / `MediaKitDoc` behind them.

Three decisions worth knowing:

**They live under `/system/`.** Profiles own the URL root, so `/investors` and
`/media-kit` would each burn a word no member could ever hold as a handle. The
member directory set this pattern at `/system/members`.

**They are English in every locale, and nothing on them goes through gettext.**
They address investors and journalists, both of whom read English as a matter of
course, and the alternative is a German translation nobody maintains, which
drifts the first time a figure changes. The footer labels them "Investors" and
"Media Kit" in the German footer too, so the change of language is visible
before the click, and each page marks its content `lang="en"`.

**Both are served on every installation, without a switch.** A media kit is
about the software's brand, which every installation runs. The investor page
speaks for whoever operates an installation, but every name, address and figure
on it is read from that installation's own operator identity and its own live
counts, so it says something true wherever it runs.

Both join the agent-format system (`.md`/`.txt`/`.json`/`.xml`), and the doc
builders own the text: `MediaKitDoc.boilerplate/0` is where the three
boilerplate lengths live, and the HTML page renders the same strings. On this
page in particular the Markdown sibling is not an afterthought, because what
fetches a media kit today is as likely to be a language model writing about
vutuv as a journalist.

### Figures on the investor page

Every number is read live per request (`InvestorsDoc.facts/0`) and handed to the
template and the doc together, so the page and its siblings cannot disagree.
They are the same figures `/system/nodeinfo/2.1` already publishes, plus the
Fediverse reach (`Vutuv.Fediverse.distinct_follower_count/0` and
`follower_host_count/0`).

Beside the two figure tiles the page **spells the addition out**: members plus
Fediverse accounts equals the total in the top bar, set as a written addition of
three labelled rows (`InvestorsDoc.people_sum_rows/1`), because investors have
asked how that number comes about and a figure nobody can decompose is a figure
nobody believes. The agent-format siblings say the same arithmetic as one
sentence (`people_sum/1`) — a column of digits has nothing to line up against in
a text file. Both read the same `facts` map.

The page is deliberately two cards: a contact card carrying the h1, and those
figures. It once carried the whole pitch (positioning against LinkedIn, the
gated-community argument, the cost base, a growth curve) and was cut back to
this on 2026-08-16. The prose is in the history if it is wanted again; the
LinkedIn framing itself lives on in the media kit's boilerplate.

### Brand assets

`priv/static/images/brand/`. The two wordmark SVGs are generated from
`priv/static/images/vutuv-logo.svg`, which is an A4 page with a wordmark
somewhere in the middle; the media-kit copies carry the measured bounding box of
its five paths as their viewBox, and set the ink colour on a wrapping `<g>`. The
icon mark is `favicon.svg`, and the 512px PNG is that file rasterized.

`priv/static` is gitignored, so these files are force-added like every other
shipped image (`git add -f`). `company_controller_test.exs` asserts that every
asset and screenshot the page offers really is served, so a missing file fails
the build instead of shipping a broken download link.

## The head-count history

`Vutuv.PeopleHistory` over one table, `people_snapshots`: one row per German
calendar day with the member count and the Fediverse head count. The live
figures are `Vutuv.PeopleCounter`'s; this is their history.

`Vutuv.PeopleHistory.Recorder` writes one row at **23:59 Berlin time**, a minute
before midnight rather than a few minutes after it, so the row carries the date
of the day it describes with no arithmetic. Both figures are running totals, so
the last minute of sign-ups it misses lands in the next day's row instead of
being lost. It schedules the exact next trigger through
`Vutuv.BerlinTime.ms_until_daily_trigger/1` like the other nightly workers, and
is off in tests (`:record_people_history`).

A re-run **replaces** the day rather than skipping it: the second write is the
later, better reading of the same day, and a restarted recorder must not leave a
gap in the curve.

**The first 30 days are a reconstruction.** The creating migration backfills
them from the rows that exist at migration time, which can only be biased one
way: a member who has since deleted their account and a follower pruned as
unreachable are missing from every day they were really there, and
`email_confirmed?` is read as it stands now. Nothing marks those days apart in
the table (a deliberate call, they are the same quantity counted as well as it
can still be counted), but the migration's moduledoc says so, and so does this
paragraph.

### The curve, drawn twice

`VutuvWeb.CompanyHTML.growth_curve/1` on the investor page, plain server-rendered
SVG. No chart library: the drawing is one path, a wash under it and two labels,
and a JavaScript bundle for that would be paid for by every reader of every
other page.

**One line, the people total**, rather than a band per population: the member
half is two orders of magnitude larger than the Fediverse half, so on any shared
scale the smaller band is a hairline along the top and says nothing. Which half
moved is said in words under the chart (`InvestorsDoc.growth_sentence/1`), where
it can be said exactly.

**The y-axis is the span the data covers, not zero to peak** — at four digits a
month of growth is a couple of hundred people, and an axis from zero draws that
as a solid block with a flat lid. A zoom like that is only honest where
something says what it spans, so the chart names both ends underneath itself:
the first and last figure, and the first and last day.

The same line is drawn a second time, as a **thumbnail in the top bar** beside
the people total (`VutuvWeb.ShellLive`), 48×16 pixels of the last 30 days. It
has no room for those end figures, which is why it says only "rising" and leaves
"how far" to the number it sits beside. Both drawings come through
`Vutuv.PeopleHistory.curve_points/3`, so how this curve is drawn is decided in
one place; only the box and what is built around the line differ.

The thumbnail is read from `:persistent_term`, never from the table: the bar is
on every page, so it has to cost what the figure beside it costs (two atomics
reads). `Vutuv.PeopleCounter` refreshes it on the tick it already reconciles the
member count with, and writes only when the shape changed. While nothing is
cached — the sub-second after boot, an installation younger than two days, a
span that never moved — the bar simply shows the number.
