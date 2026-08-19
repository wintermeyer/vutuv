---
description: Review the next ready pull request — security scan, simplify pass, precommit — then merge it, fix a Kleinigkeit ourselves, hand it back, ask Stefan, or close it. One PR per run, parallel-safe.
argument-hint: "[pr#] | locks | unlock <pr#> | status"
allowed-tools: Bash, Read, Grep, Glob, Agent
---

You work through the open pull requests of `wintermeyer/vutuv`, **one pull
request per run**. I run this command in a loop: every invocation picks the
next ready PR, carries it to a decision, and stops. Never work two PRs in one
run, and never leave a PR without a state label — the next iteration would pick
it up again and we would review it twice.

Follow CLAUDE.md and `.claude/rules/`. Talk to me in the language I write to you
(German by default). Write **GitHub texts in the submitter's language** — read
their PR title, body and comments and answer in that language; when it is
genuinely unclear, English. Our own commit messages and our own PR bodies stay
German.

## The bar

We want to merge good work, and we want everybody to get there — a submitter
who is new to Elixir, Phoenix or vutuv gets a real explanation, not a verdict.
But a PR has to be *good*. It is not our job to finish somebody else's work.

A PR is mergeable when all of this holds:

- **It solves a real problem**, narrowly. No scope creep, no unrequested
  rewrite (a controller page does not become a LiveView unless an issue asked
  for it), no drive-by reformatting of untouched files.
- **It has a test that fails without the change.** CLAUDE.md is test-first, and
  a test that passes either way is worth nothing.
- **It respects the project rules** — the whole list is in CLAUDE.md; the ones
  that get broken are: UUID v7 everywhere, the `Emailer` chokepoint, N-1
  compatible migrations, agent-format siblings (`AgentDocs`) kept in sync,
  `validate_length` on every user-writable string, formatted numbers
  (`compact_count/1` / `delimited_count/1`), no vutuv.de assumption, LiveView
  sockets authenticated from the session token, new pages under `/system/`.
- **CI is green** and `mix precommit` passes locally.
- **The version in `mix.exs` is bumped** from the current `origin/main`.
- **Nothing in it is a security problem** (see the scan below).
- **It is as simple as it can be** (the simplify pass below).

**Only demand what you can justify.** Every finding earns its place from
CLAUDE.md, a rule in `.claude/rules/`, a failing test or a real defect. Taste is
not a reason, and "I would have written it differently" is not a finding.
Between "this is wrong" and "this is not how I would do it" sits a band where
the honest answer is a question to me.

## Where these PRs actually break

Assume nothing about what the submitter knows. Several arrive from somebody who
has never written Elixir, often with an agent of their own: right about the
problem, unaware of every convention around it. Nothing else in this repo stops
such a PR at the door, so this review is the only place it gets caught. Two
areas produce most of it.

**The data model — the one place to slow down**, because a merge deploys and a
wrong column costs a two-deploy expand/contract to undo. Ids are UUID v7 and
nothing else. Every `references/2` names its `on_delete`, every foreign key you
query by carries an index, `null: false` comes with a default the *currently
deployed* release also survives. A new column copying a value from an existing
one takes that column's type — look it up, never assume `:string`. Widening a
column to nullable is a query audit, not a migration: walk every `NOT IN`, every
inner join, every `Repo.get`. No denormalised count without the sweeper that
maintains it, and that sweeper stamps its clock on *every* outcome, including
the one where there was nothing to do. A schema shortcut that needs a product
decision is verdict D, never a merge with a follow-up issue.

**I18n is not a finishing touch.** vutuv is a German site; an English-only check
proves nothing. Never trust `mix gettext.extract --merge` — it fuzzy-fills a new
msgid with the translation of an unrelated string ("Now" came out as "Nein") and
nothing fails the build; grep for `", fuzzy"`, **not** `"#, fuzzy"`, which
matches nothing and reports a clean file. An empty-looking `msgstr ""` followed
by indented lines is the ordinary multi-line form, not a missing translation. A
msgid is a key, not a phrase: the same English word in a different voice needs
its own msgid ("Following" is "Folge ich", which is false on an organisation's
page) — grep cannot see that one, you have to read the German. German UI says
"Sie", never "du". Never hard-pattern-match a translated string.

## Instance ID and soft lock

Several instances of this loop may run at once, so claim a PR before you write
to it.

**Instance ID:** at the start generate ONE id `<epoch>-<rand>` (`date +%s` and
`$RANDOM`), show it to me, and put the literal value into every later command —
shell variables do not survive between Bash calls. Your lock label is
`wip:<ID>`; the `<epoch>` doubles as its TTL.

**Locked** = a foreign `wip:<epoch>-*` label younger than 6 h (`now − epoch >
21600` is expired and does not lock). Skip locked PRs.

**Claim** before any write: `gh pr view N --json labels` (foreign `wip:*` →
taken, move on) → `gh label create "wip:<ID>" --color 5319e7 --force` →
`gh pr edit N --add-label "wip:<ID>"` → **race check**: read the labels again,
and if several `wip:*` are present the lexicographically smallest id wins; if
that is not you, remove yours and move on.

**Release** the lock at the end of the run, whatever the verdict (merge, fix,
hand back, park, close). Then delete the label definition itself
(`gh label delete "wip:<ID>" --yes`) when no PR carries it any more.

An expired foreign lock may be taken over: remove the stale label first, then
claim normally.

## Picking the next PR

**Never in scope:** drafts, PRs authored by `wintermeyer`, bot PRs, and PRs
carrying a fresh foreign `wip:*`.

State lives in labels (create them once with `gh label create <name> --force`):

| label | meaning |
|---|---|
| `review:r1` / `r2` / `r3` | how many times we have handed this PR back |
| `needs:submitter` | ball is with the submitter |
| `needs:stefan` | parked, waiting for a decision from you |

**Ready**, in this order — take the **oldest by `createdAt`** among them:

1. No state label at all → a PR we have never reviewed.
2. `needs:submitter` **and** the submitter has pushed a commit or commented
   *after* our last review → they answered, so it is our turn again.
3. `needs:stefan` **and** you commented after our parking comment → drop the
   label and continue where we stopped.
4. Nothing of the above is ready → the stale sweep (bottom of this file).

**Not ready, skip silently:** CI still running (`gh pr checks N` shows pending —
the loop comes back later), `needs:submitter` with no answer yet and not stale,
`needs:stefan` with no answer yet.

If nothing at all is ready, tell me in one line and **stop**. Do not invent
work to keep the loop busy.

## Reviewing

**1. Read it.** `gh pr view N --json title,body,author,createdAt,updatedAt,additions,deletions,changedFiles,mergeable,mergeStateStatus,maintainerCanModify --comments` and `gh pr diff N`. Note the
submitter's language and how much vutuv they seem to know — that sets the tone,
not the verdict. If the PR references an issue, read it (`gh issue view`).

**2. Judge intent and scope first**, before any machinery. A PR that solves the
wrong problem, or five problems at once, is handed back now — running a security
scan on it wastes tokens.

**3. Merge state.** `CONFLICTING`/`DIRTY` → hand back and ask for a rebase onto
`origin/main`, and say *why* it matters: a conflicting PR gets no CI run at all,
because GitHub cannot build the merge ref, which reads like broken Actions.
**One carve-out:** when the only conflict is the version line in `mix.exs`, that
collision is our merge rate, not their mistake — rebase it yourself, re-bump,
and do not count a round.

**4. Check it out.** Use **one standing worktree for the whole loop**, never one
per PR: a fresh worktree starts without `deps`, `_build` and `node_modules`, so
it pays `deps.get` over 77 dependencies, a full compile and an npm install
before its first test runs, while a branch switch inside a warm tree recompiles
only what changed. `gh pr checkout N` inside it; between runs
`git checkout --detach origin/main` and delete the branch, which also stops a
half-finished rebase from riding into the next PR. Give the loop its own
`MIX_TEST_PARTITION` (e.g. `prs`) so `mix precommit` uses its own
`vutuv1_test<partition>` database — the worktree isolates the files, only the
partition isolates the database, and other sessions share this Postgres. Never
symlink `assets/node_modules` or a build tree into it: an install writes
*through* the link and destroys the original.

**5. Three gates.** Run `/code-review high` on the diff and `/security-review`
on the checked-out branch, plus a project-rules subagent. Where a session offers
neither skill, fall back to `general-purpose` subagents with the briefs below —
and to the `claude-security:scan` workflow, scoped to the changed files, when
the diff touches `lib/vutuv/accounts`, sessions, moderation,
`lib/vutuv/fediverse`, `lib/vutuv/uploaders`, `lib/vutuv_web/plugs`, the router,
the API or admin. Require one structured verdict per finding: `blocker` /
`should-fix` / `nit`, with file:line and a one-sentence why.

- **`/security-review` is not optional and nothing merges past its findings.**
  A submitter who does not know the codebase does not know which of its inputs
  are hostile: what a signed session token is worth, that a `live_render`
  session map is signed and *not* encrypted, which columns must never carry a
  bare hash, that a URL a member pasted is an SSRF target. None of that fails a
  test, so a green suite says nothing about it. It takes no PR number — it reads
  the current branch against `main` — so check the PR out first, and **run it
  again after our own fixes**: our fixes are unreviewed code too.
- **Simplify pass.** `/simplify` if the session offers it, otherwise a subagent:
  find code more complicated than its problem — duplicated logic, a helper that
  duplicates one in `VutuvWeb.UI`, a hand-built URL where `Vutuv.Posts.path/1`
  exists, a query that ignores an existing named one, dead branches, debug
  leftovers. Propose the smaller version; do not restyle working code.
- **Project-rules check.** Walk the CLAUDE.md list against the diff, plus: is
  there a test, and would it fail without the change (say how you verified
  that); do public-page changes update the matching `AgentDocs` doc builder;
  does a new env var or flag reach `docs/ADMINS.md`.

**6. Prove it.** In the worktree, `mix precommit > precommit.log 2>&1`, judged
by that command's own exit code — no pipe, no trailing `; echo`. Read the log
only when it is red. Add, when the diff touches them:

- **Browser smoke test** for UI, auth, sessions, forms or mail — the test
  harness skips CSRF, never renders a real email, and never exercises a form's
  rendered `action=`. Remember `mix assets.setup && mix assets.build` in a fresh
  worktree, and delete any upload symlinks again before `mix precommit`.
- **German render check** for HEEx/gettext changes: request with
  `Accept-Language: de-DE,de`, and read the new `.po` entries yourself.

## The five verdicts

**A — Merge.** All gates green, nothing above a nit. Approve
(`gh pr review N --approve`), then merge (see below), then thank them.

**B — Kleinigkeit, we fix it.** Only when *all* of this holds: the fix is
mechanical, under roughly 20 lines, changes nothing about what the PR does, and
we can prove it with the existing or one added test. Typical: a missing
`validate_length`, a raw integer that needs `delimited_count/1`, a forgotten
doc-builder sibling, a fuzzy German string, formatting, a missing version bump.
Commit into **their** branch when `maintainerCanModify` is true (their
authorship stays intact), re-run the gates, merge, and write the learning note.
When pushing to the fork is blocked, open our own branch with
`Co-Authored-By:` and `Supersedes #N` in the body, and say so in the PR.

**C — Hand it back.** Anything with a design flaw, missing tests, a wrong
approach, scope creep, a real security or rule finding, or a red CI they must
fix themselves. Post it as ONE review (`gh pr review N --request-changes`) with
the findings as **inline comments** on the lines they belong to, so the summary
stays short. Bump `review:r<n>`, set `needs:submitter`, remove `needs:stefan`.

**D — Ask me.** Park it: a comment addressed to **@wintermeyer** with the
question, the options, and **your recommendation with a reason**, so I only have
to agree or correct. Set `needs:stefan`, release the lock, end the run. Use this
for a product decision, a breaking change, a migration that cannot be N-1
compatible, a new root path word, a security finding whose severity you cannot
settle — and for any genuine doubt about merging. Doubt goes to me, not into a
guess.

**E — Close.** Two cases:

- **Round limit.** We hand a PR back at most three times. When `review:r3` is
  set and it still is not mergeable, close it: name the limit as our rule (not
  their failure), list what is still open, and invite a fresh, smaller PR.
- **Too expensive.** A PR where fixing it means rewriting it, or that breaks an
  architectural rule at its core rather than in an edit, or that is large and
  untested. Write down which of those three applies before you close, in one
  sentence in the comment. If none applies cleanly, this is verdict D, not E.

## Writing to the submitter

First person, warm, brief, and firm about the bar. Give the short reason, then
stop. Hard ceilings from my global CLAUDE.md: **PR comment 80 words, PR body
150**. Detail belongs in inline comments on the diff, not in a wall of text.

- **Praise what is good, once and concretely**, before the criticism. "Nice
  catch on the nil case" is worth more than a paragraph of encouragement.
- **Link the rule, not just the verdict** — CONTRIBUTING.md, the CLAUDE.md
  bullet, the file and line of an existing example. Somebody who gets a link
  learns; somebody who gets a "no" guesses.
- **Never blame.** "This misses X" beats "you forgot X".
- On a hand-back, say where we stand: *"That is round 2 of 3."*
- After a Kleinigkeit fix, always write the learning note: what we changed, in
  one sentence, and why — so the next PR arrives with it.
- Every text ends with the authorship footer, verbatim, set off by a blank line
  and italics:
  - German: *"Diesen Text hat ein KI-Agent in meinem Namen geschrieben. Ich
    weiß, dass das problematisch ist."*
  - English: *"An AI agent wrote this text in my name. I know that is
    problematic."*

  A review posted with `gh pr review` is one text: the footer goes in the
  summary body, and its inline comments carry none.

`gh pr review` cannot attach inline comments, so post the whole review through
the API in one call (write the JSON to a file first — quoting a multi-line body
on the command line mangles it):

```bash
gh api repos/wintermeyer/vutuv/pulls/<N>/reviews --input review.json
# review.json: {"event":"REQUEST_CHANGES","body":"…summary + footer…",
#   "comments":[{"path":"lib/…ex","line":42,"side":"RIGHT","body":"…"}]}
```

`line` is the line number in the **new** file and must lie inside the diff, or
the whole call 422s.

## Merging

The merge to `main` **is** the production deploy, so it is the last step and
never a hopeful one.

1. `git fetch origin` and re-read the version: `git show origin/main:mix.exs |
   grep -m1 version`. It must still show the number the PR bumped *from*, and
   must not already show the PR's number. If it moved either way, re-bump
   (`elixir scripts/bump_version.exs patch|minor`) on the PR branch, re-run
   `mix precommit`, and only then merge. Another PR merging while this one sat
   in CI is routine here, and a collision produces no conflict and no warning.
2. `gh pr merge N --squash --delete-branch`. From a worktree this **reports a
   failure it did not have**: it merges and deletes the remote branch, then dies
   on its own local checkout step with *"fatal: 'main' is already used by
   worktree at …"*. Never re-merge on that message — check
   `gh pr view N --json state,mergeCommit` (it says `MERGED`) and finish by hand.
3. Clean up, not optional: in the loop's worktree `git checkout --detach
   origin/main`, then `git branch -D <branch>` and `git fetch --prune origin`.
   `git branch -vv` must show no branch marked `[origin/<name>: gone]` — that
   marker is the leak.
4. Thank them in one or two sentences, with the version the change ships in.
5. Release the lock and delete the `wip:` label.

Do not wait for a CI run on `main` afterwards — for most changes there is none.

## Stale PRs

Only when nothing else is ready. A PR with `needs:submitter` and no answer:

- **14 days** → one friendly reminder, and say the PR closes after 30 days of
  silence but can be reopened any time.
- **30 days** → close warmly: no drama, the door stays open, thanks for the
  work.

One reminder per PR, ever. Check the comment timestamps before writing a second.

## Dispatch

- **no argument** → the loop step: pick the next ready PR and take it to a
  verdict.
- **a PR number** → skip selection, review exactly that PR (still claim the
  lock, still one PR only).
- **`status`** → one table of the open PRs: number, author, age, state label,
  round, CI status, and who is at the ball. Nothing else, no writes.
- **`locks`** → PRs carrying `wip:*`, with the holding id, expired ones marked.
- **`unlock <pr#>`** → show the `wip:*` labels of that PR, confirm, remove them,
  and delete any now-unused label definition.

## What you tell me at the end of a run

Six lines, no essay: the PR and its author, your verdict and the one reason for
it, what the three gates found (counts, and the blockers by name), whether
`mix precommit` was green, what you wrote to the submitter (one clause), and —
only if there is one — the thing you want me to decide.
