# Writing an issue

An issue is read in one minute by somebody who does not hold this codebase in
his head, and who is deciding three things at once: does he want it, is it the
next thing, and is it diagnosed correctly. Everything below serves that minute.

## The shape

Three sentences of prose, then one `Where:` line. That is the whole issue.

1. What happens today, in words somebody who has never opened the code
   understands.
2. What should happen instead.
3. Who notices, and what it waits on or what waits on it.

Then a single line naming where to start (a URL, a module, a function):

    Where: VutuvWeb.ShellLive, the bottom bar on a phone

One line, not an inventory. Whoever picks the issue up reads the code anyway;
the line only saves them the search.

**Who notices** has three answers, and the sentence says which: a **member**
using vutuv, an **operator** running their own installation, or **nobody
outside the code**. "Members see nothing change" is a complete and useful
sentence, and it is how a reader knows to stop reading.

## What not to write

No `**TL;DR**`, no `**Now:** / **Want:**` headings, no bullet list of
sub-features, no contrast ratios, no call-site counts. The labelled-field shape
looks organised and reads as six things to hold at once instead of one.

Leave out what the code already says. An issue that lists eight `rel` spellings
with their frequencies spends the reader's minute doing the implementer's first
ten. Say the links disagree; the implementer will count them.

## The title names something you can point at

A title is all that shows in the list, so it has to carry the issue alone. Name
a **surface**: a page, a control, a link, a mail. Then say what changes about
it. Naming a code construct instead is what makes forty open issues unreadable.

| Code construct | Surface |
| --- | --- |
| Give outbound links one owner for their `rel` attribute | Outbound links disagree about what the target site learns |
| Share one refresh loop across the three snapshot caches | The who-to-follow lists each keep their own refresh timer |
| Implement featured hashtags, or stop advertising API version 6 | Mastodon clients offer featured hashtags that vutuv cannot serve |

An internal change still has a surface. "The who-to-follow lists" is something
you can picture; "the three snapshot caches" is not.

## Two worked examples

### Internal, nobody outside the code notices

> **The who-to-follow lists each keep their own refresh timer**
>
> The most-followed listing and the profile's who-to-follow suggestions each
> cache their ranking behind a copy of the same thirty-line refresh timer, so
> the next cached list will copy it a third time. I would extract one module
> they share.
>
> Members see nothing change. Nothing waits on it.
>
> Where: `Vutuv.Social.PopularUsers` and `Vutuv.Posts.TopPosters`

### A bug a member runs into

> **The bottom tab you are on is the palest of the five**
>
> On a phone, the active tab in the bottom bar is fainter than the four you are
> not on, so there is no way to tell where you are. It should read as active at
> a glance — a filled icon, the way iOS and Android both do it.
>
> Every member on a phone sees this. Nothing waits on it.
>
> Where: `VutuvWeb.ShellLive`, `tab/1`

Both are under sixty words, and neither hides anything the implementer needs.

## Before you open it

- Is the title a surface, or a code construct?
- Would somebody who has never seen this repo know what changes?
- Does one sentence say who notices?
- Is there a labelled field left that prose would carry better?

An issue is cheap to ask a follow-up question about and expensive to read
twice. When in doubt, cut.
