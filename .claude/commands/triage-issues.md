---
description: Autonomous triage sweep over the open issues — normalize titles, set category + area labels, close what is verifiably done, report the judgement calls
argument-hint: "[issue#] | dry-run"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(date:*), Read, Glob, Grep, Agent
---
You sweep my open vutuv issues once, autonomously, and report at the end. This
is the **triage** half of the old `/issues`: labels, titles, closes. It never
writes code, never opens a PR, never touches a branch. Fixing is `/issues`.

Follow CLAUDE.md for every GitHub text: language of the issue (not of our
conversation), authorship footer, no production hostnames, no internal data.
Talk to me in the language I write to you.

**Autonomous means autonomous.** Do not ask me one question per issue. Read the
backlog, decide, write, and put the whole result in front of me at the end. The
only things that wait for me are the judgement calls listed under "Never on your
own".

## Dispatch
- **no argument** → the full sweep below.
- **`dry-run`** (also `trocken`, `probe`) → do everything including the
  done-checks, write **nothing**, print the report as a plan. Use this if I
  ask "what would you do".
- **an issue number** → the same flow for that one issue only.

## Step 1: read the backlog (one call)
```bash
gh issue list --state open --limit 200 \
  --json number,title,labels,author,assignees,createdAt,comments,body \
  --jq '.[] | {number, title, author: .author.login, labels: [.labels[].name],
               comments: (.comments|length), body: .body[0:1500]}'
```
Then, before deciding anything:

- **Snooze wake pass** (moved here from `/issues`): an issue whose
  `snooze:YYYY-MM-DD` label is ≤ today loses both `snoozed` and `snooze:<date>`
  and joins this sweep; delete a now-empty `snooze:*` label. Future ones are one
  report line, `💤 N snoozed`, and are otherwise not read.
- **Foreign locks**: an issue carrying a `wip:<epoch>-<rand>` label whose
  `<epoch>` is younger than 6 h belongs to another session. **Skip it entirely**,
  read-only, and list it in the report. You take no lock of your own: your writes
  are single `gh` calls, and the sweep must not leave `wip:` litter behind.
  Skip an issue assigned to `wintermeyer` **and** carrying `in progress` too:
  that is work in flight.
- **What is already in flight.** Most of this backlog is not untended work, it
  is a review queue: on the first real sweep, 29 of 51 open issues had an open
  pull request. Read them once and map them by their bodies, never by matching
  titles:
  ```bash
  gh pr list --state open --limit 100 --json number,title,body
  # then: the #<n> references in each body that name an OPEN issue
  ```
  An issue with an open PR is **in flight**: never close it, never call it
  stale, and mark it in the report. It still gets its label and its title.
- **Scope**: every remaining open issue, including the ones that already carry a
  category. Step 3's test is applied to all of them and you may overrule what is
  already there, in either direction. Retire `enhancement`: it is
  `Feature Request` unless the test puts it in `Tech Debt` or `Design`, so swap
  it on every open issue. **Do not delete the label**:
  it still marks 182 closed issues and 7 pull requests, and deleting it strips
  every one of them. That holds for any label with history — an empty-on-open
  label is not an unused label, so count the closed ones first and put a
  deletion to Stefan instead of making it. Leave `v1.x` alone.

## Step 2: done-checks, in parallel
An issue that reads as if it might already be shipped is a **candidate**. Run
`git fetch origin` first, and tell every agent to read through
`git show origin/main:<path>` and `git grep <pattern> origin/main`: a worktree
session is routinely several commits behind, and a verdict off a stale working
tree is worth nothing. Two cheap signals pick the candidates:

```bash
# a PR that mentions the issue shows up as a cross-reference
gh api repos/:owner/:repo/issues/N/timeline \
  --jq '[.[] | select(.event=="cross-referenced") | .source.issue.number]'
gh pr list --state merged --search "N" --limit 5 --json number,title,mergeCommit
```

**`git log --grep '#N'` is not one of them.** A squash merge here puts the *PR*
number in the subject, never the issue number, so that search stays silent for a
shipped issue and silence reads as "still open". The third signal is judgement:
an issue older than a month about a surface that has since been rebuilt.

Dispatch **one read-only `Explore` agent per candidate, all in one message**, up
to 8 at a time. Give each the issue number, title and body, and this job:

> Does current `origin/main` already do this? Answer with one of
> `VERDICT: SHIPPED` + the commit SHA **and** the `file:line` that implements it,
> `VERDICT: PARTIAL` + what is still missing, or `VERDICT: OPEN` + where it would
> have to live. Never guess: no proof means OPEN.

A static reading is a hypothesis (CLAUDE.md), so **only `SHIPPED` with both a SHA
and a `file:line` is proof**. `PARTIAL`, a verdict without proof, or an agent
that hedges → the issue stays open and goes into the report.

**Read a "that module does not exist" verdict twice.** Issues here are often
written against an open PR's branch, so the module they name (`Vutuv.LinkSummary`,
`tag_attributes/1`) is genuinely absent from `main` while the issue is perfectly
current. That is `OPEN`, never "stale" — check the in-flight list from Step 1
before you doubt the report. What it *does* earn is a line in the report: an
issue whose stated `Where` no longer matches `main` is worth re-checking before
somebody starts on it.

For a `SHIPPED` verdict, name the PR the fix rode in on and its merge date, from
the commit the agent proved or from the PR the cross-reference named (there is
no version number; the commit is what identifies a release):
```bash
git log -1 --format='%h %cs %s' <sha>
gh pr view <pr> --json number,mergedAt
```

## Step 3: decide, per issue
### Category — exactly one of four
Every open issue ends the sweep carrying exactly one of `Bug`,
`Feature Request`, `Tech Debt`, `Design`. Never two, never none.

**One question decides it: does this fail a promise the system already makes?**
Not "is the code broken", and not "was this ever written" — a promise can
predate its implementation by years. Four things count as a promise:

1. an **interface we advertise** — the Mastodon API, ActivityPub, the agent-format
   siblings, an env var in `docs/ADMINS.md` — against what it actually returns;
2. a **standard we claim** — WCAG, an RFC, a spec we say we implement;
3. **parity between two surfaces of the same thing**: the website shows a post's
   link preview, the app of the same post does not;
4. the **code's own evident intent**, where the result is the opposite of it.

None of the four holds → nobody has been let down yet, and it is one of the
other three:

- `Bug` — a promise above is broken. Something is *wrong*, not merely absent.
- `Feature Request` — a capability nobody promised: new surface, new behaviour,
  or a best-effort feature asked to try harder.
- `Tech Debt` — it does what it should and the *way* it does it is the problem.
  Performance, an architecture that will not hold, a refactor, one concept
  living in three modules, a flaky test, CI plumbing.
- `Design` — visual, layout, wording and UX work that breaks no promise: a
  redesign, a nicer empty state, a spacing pass.

Apply it to the body's **Now** and **Repro**, never to the title. Titles here
have already been normalised into imperatives, and an imperative hides which of
the four this is — that is exactly how eight issues came to be labelled `Bug`.

Worked examples from this backlog, chosen because each one looks like a
different category than it is:

```
#1715  the Mastodon presenter hardcodes `card: nil` while the website
       shows the preview                                  → Bug
       Never implemented, and still a Bug: we advertise that API (1) and
       the same post already answers differently on two surfaces (3).

#1728  the active bottom tab is the palest of the five, 1.13:1 against
       the inactive ones                                  → Bug
       Renders exactly as coded, and still a Bug: the code's intent is to
       mark the active tab and the result un-marks it (4), and WCAG 1.4.1
       is a standard we claim (2).

#1707  a link-preview capture shows the cookie dialog, not the page
                                                          → Feature Request
       Wrong output from working code, and still not a Bug: autoconsent
       handles the CMPs it has a rule for and is fail-open by design, so
       nothing was ever promised about zdf.de. The Want asks for new
       heuristics, which is new capability.

#1742  the link summary runs inline on the screenshot worker and stalls
       the queue for ~2.5 minutes                         → Tech Debt
       Runs as designed. The design is what does not hold under load.
```

**"It was never implemented" and "the code runs fine" are both non-answers** —
they got #1715 and #1707 backwards. Ask about the promise.

**Cross-check a `Bug` against the gate it is about to meet.** `/fix-bugs` starts
by writing a failing test from the *existing* code and its neighbours; if the
assertion only makes sense once somebody has decided what the new thing should
do, that command throws the issue back. So ask it here, where it is cheap: could
a test be written today that fails? A `Bug` whose fix needs a new column, a new
worker or a product decision first is one you have mis-categorised — the promise
you found is real, and the work to keep it is not a repair.

**You may overrule a category that is already there, in both directions**,
including one I set and one an earlier run of this command set. Every flip is
one report line: the issue, `from → to`, and which promise it breaks or does not.
A flip you cannot justify in that line is one you have not thought through —
leave the label alone and put it under "Needs you".

The two newer categories may be missing from a fresh clone:

```bash
gh label create "Tech Debt" --color 0052cc \
  --description "Does what it promises; the way it does it is the problem" --force
gh label create "Design" --color d4c5f9 \
  --description "Visual, layout and UX work that breaks no promise" --force
```

**Why this label and not another is the one worth getting right:** `/fix-bugs`
drains `Bug` unattended, and its own gate (can you write a failing test from the
*existing* code?) throws back everything else — so a mislabel costs a fixer slot
and an apologetic comment to the author. `Tech Debt` and `Design` are walked by
`/issues`, with Stefan in the loop.

**Area labels**, only the ones that already exist and only when obvious: at most
one of `Fediverse`, `Security`, `Documentation`, `frontend`, `CSS and HTML`, plus
`good first issue` where it genuinely fits. No area label is better than a wrong
one.

**Titles: imperative, what should happen.** Every title says what to do, in the
issue's own language:

- Present-tense imperative, no trailing period, **≤ 72 characters**.
- Name the outcome, not the implementation. You often do not know the fix, and a
  title that guesses one is worse than the symptom it replaced.
- Where the imperative would hide the symptom, keep the symptom after a colon:
  `Make the top bar stay put: its sticky has no effect`.
- Never assert something the body does not say, and keep the author's vocabulary
  (their word for the feature, their spelling of a module). You are reshaping a
  sentence, not restating their report.
- No ticket prefixes, no `[area]`, no issue number, no jargon that only makes
  sense with the code open.

**For a `Bug` the colon rule above is not optional.** The bare imperative erases
the one thing the next reader categorises by: "Make the bottom tab clearest"
reads as a wish, and that is how it gets re-labelled wrong. Every `Bug` title
therefore carries its symptom, as a negative imperative or after a colon. The
other three categories keep the plain imperative.

```
Bug        The top bar scrolls away: its sticky has no effect at all
        →  Make the top bar stay put: its sticky has no effect
           (not "Make the top bar stay put while the page scrolls" —
            that is the same sentence with the defect taken out)

Tech Debt  Six copies of the same ETS-owner GenServer want one Vutuv.EtsCache
        →  Share one ETS cache instead of six copies of the same GenServer

Bug        PeopleCounter crashes on every cold boot: Endpoint.host/0 too early
        →  Stop PeopleCounter from crashing on every cold boot
```

Write it with `gh issue edit N --title "..."`, and set labels in the same call
(`--add-label` / `--remove-label`) so one issue costs one write.

## Critical bugs: mark them, then interrupt me
A bug where **a member or the site is being harmed right now** does not wait for
the end of the report. Mark it, notify me the moment you identify it, and lead
the report with it.

**Critical is:** data loss or corruption; anything private becoming visible (a
visibility or permission hole, a leak into a log or a public repo); a security
hole; a dead end on a path everybody walks (login, signup, posting, the feed, a
profile); mail that silently is not delivered.

**Critical is not:** cosmetic, slow, a refactor, a flaky test, one page with a
workaround, a failure in a single third-party client. **When you hesitate, it is
not critical** — the mark is worth something only because it is rare. It rides
beside `Bug` and never alone; a feature request is never critical.

```bash
gh label create critical --color b60205 \
  --description "A member or the site is being harmed right now" --force
gh issue edit N --add-label Bug --add-label critical
```

**Notify immediately**, one banner per critical issue, at most 3 plus a line
saying how many more. `-open` makes the banner itself clickable.

**The banner is macOS-only, so ask before you fire it.** `terminal-notifier` and
`osascript` are both macOS, and vutuv is developed on Linux too, where the same
line prints `command not found` and the run reads as if it notified. Gate on
`uname`:

```bash
if [ "$(uname -s)" = "Darwin" ]; then
  terminal-notifier -title "vutuv: critical bug" \
    -subtitle "#1802 Private posts visible to logged-out readers" \
    -message "Click to open the issue" \
    -open "https://github.com/wintermeyer/vutuv/issues/1802" \
    -sound default \
    || osascript -e 'display notification "#1802 Private posts visible to logged-out readers" with title "vutuv: critical bug"'
fi
```

Off macOS, skip both silently and say in the report that no banner was possible
here. Call the harness's own `PushNotification` **on every platform** with the
issue number, title and URL: it is the only channel that works everywhere, it
reaches Stefan's phone when Remote Control is connected, and it stays quiet when
he is sitting at the terminal anyway.

**A notification that did not go out is itself a finding.** On macOS
`terminal-notifier` needs permission (System Settings → Notifications →
terminal-notifier → Allow Notifications) and exits **3** with *"Notifications
are not allowed for this application"* until it is granted; `osascript` exits 0
whether or not a banner was drawn, so it proves nothing. Judge it by the exit
code, and when the banner could not be sent, say so in the report's critical
block rather than assuming it arrived.

## Closing: hard proof only
You close an issue on your own in exactly two cases:

1. **Shipped**, with a `SHIPPED` verdict carrying a SHA *and* a `file:line`, and
   the issue asks for that and not for more.
2. **Duplicate**, where another open issue covers the same symptom in the same
   subsystem and is equal or wider in scope. Close the narrower or newer one,
   keep the other, link both ways.

Everything else (wontfix, out of scope, stale, "makes no sense", a design we do
not want, a `PARTIAL` verdict) is a **judgement call and goes into the report**
with your recommendation and a draft note. Never close it yourself.

**Never close silently** (CLAUDE.md): post the note first, then close.
```bash
gh issue comment N --body "..."
gh issue close N --reason completed      # duplicates and declines: not planned
```

The note is two or three sentences and its substance is the **why**. Scale it to
what the author does not already know: a bug they diagnosed correctly needs
nothing but thanks. Then the contact line, then the footer, both in the issue's
language:

```markdown
This landed in v7.348.0: a photo waiting for the AI scan now shows a pixelated
preview instead of the grey tile.

If you think this was the wrong call, tell me: I'm at
https://vutuv.de/wintermeyer, reachable by email or vutuv DM.

*An AI agent wrote this text in my name. I know that is problematic.*
```

```markdown
Das ist seit v7.348.0 erledigt: Ein Foto, das noch auf die KI-Prüfung wartet,
zeigt jetzt eine verpixelte Vorschau statt der grauen Kachel.

Halten Sie das für die falsche Entscheidung, sagen Sie mir Bescheid: Sie
erreichen mich über https://vutuv.de/wintermeyer, per E-Mail oder vutuv-DM.

*Diesen Text hat ein KI-Agent in meinem Namen geschrieben. Ich weiß, dass das
problematisch ist.*
```

The contact line goes on **every** close, the shipped ones included: a wrong
"this is already done" deserves an objection as much as a wrong decline.

## Asking for a screenshot or a URL
Some reports cannot be understood without seeing the thing. When one of those
arrives, ask the author, post the question yourself, and set `needs:submitter`
so the issue is visibly waiting. This is the **one** comment triage writes on an
issue that stays open.

Ask only when **both** hold:

1. A picture or an address would settle it: a visual defect (layout, contrast,
   the wrong thing rendered), a failure on one particular page, or a report that
   names an app or client but not what it put on screen.
2. The issue does not already carry it. The bug template's **"Screenshot, time,
   browser"** field is empty or `_No response_`, no image is attached, and the
   body names no URL, route or `file:line`.

**Do not ask when:**
- The body already names a route, a module, a `file:line`, a curl line or a
  repro command. That *is* the reproduction, and asking for a picture on top
  reads as if nobody read the issue.
- It is a feature request for something that does not exist yet: there is
  nothing to photograph. A redesign of an existing surface is the exception, and
  there the picture worth asking for is one of *today*.
- The issue already carries `needs:submitter`, or an earlier sweep already
  asked. Check with `gh issue view N --comments` before writing: **one ask per
  issue, ever.** A second one is nagging, and it is the first thing a repeat run
  gets wrong.
- The author has already answered a previous ask. Then do the opposite: remove
  `needs:submitter` and treat the issue as ready.

Ask for **at most two things** in one short comment, and say what you could not
work out without them, so it reads as a question and not as a form rejection.
Language of the issue, contact line, footer:

```markdown
Thanks for the report. Could you add a screenshot of what Tokodon shows at that
point, and the URL in your address bar? I cannot reproduce the 404 yet, and the
picture usually settles it.

If a screenshot is awkward here, send it to me at https://vutuv.de/wintermeyer,
by email or vutuv DM.

*An AI agent wrote this text in my name. I know that is problematic.*
```

```bash
gh issue comment N --body "..."
gh issue edit N --add-label "needs:submitter"
```

## Never on your own
- Any close that is not one of the two proven cases above.
- Any comment on an issue that stays open, **except** the screenshot/URL ask
  above. Anything else the author has to answer (unclear scope, a product
  question, a design alternative) is drafted into the report and left there for
  `/issues` to post.
- Editing an issue body, milestones, assignees, or anything on a locked issue.
- Creating a label the repo does not have — the four categories and `critical`
  excepted.
- Reopening, or overturning a category I set myself in an earlier run without
  saying why in the report.

## The report
One block at the end, no per-issue narration on the way there.

```
🚨 CRITICAL (1) — notified 14:02, banner delivered
  #1802  Private posts are visible to logged-out readers
         https://github.com/wintermeyer/vutuv/issues/1802

Triage — 52 open, 44 untriaged

  Bug               8        titles changed   38
  Feature Request  22        area labels       9
  Tech Debt        14        enhancement → Feature Request: #1666 #1331
  Design            7
  skipped (locked)  1

Re-categorised (2) — each with the promise it breaks or does not
  #1742  Bug → Tech Debt        runs as designed; the design stalls the queue
  #1707  Bug → Feature Request  autoconsent is fail-open by design, nothing
                                was promised about that site

Closed (2, proof verified)
  #1234  shipped v7.348.0, f059b4dd, uploaders/post_image.ex:88
  #1610  duplicate of #1611

Needs you (3) — nothing written yet
  1. #1705  address book access. I'd decline: no consent path, and the
            data is other people's. Draft note ready.
  2. #1591  Mastodon filter API. Verifier says PARTIAL, the stub is still
            there but we advertise v5. Fix or narrow the advertised version?
  3. #1766  the clamp module sits under the feed namespace. Real, but is it
            worth an issue?

Asked the author (1) — posted, needs:submitter set
  #1692  Tokodon: no screenshot, no URL for the 404.

Needs the author (1) — drafted, not posted
  #1128  emoji reactions: scope unclear.

⏰ woke up: #1583        💤 2 snoozed        🔒 #1777 (foreign lock)
```

Then stop. Do not slide into fixing anything: that is `/issues`.
