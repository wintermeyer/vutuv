---
description: Walk the triaged vutuv bugs and feature requests one by one, fix, PR + merge; parallel-safe via a soft lock
argument-hint: "[issue#] | locks | unlock <issue#>"
allowed-tools: Bash(gh:*), Bash(date:*), Read, Glob, Grep, Agent
---
You guide me through my vutuv issue backlog, **the labelled part of it**.
Categorizing, retitling and closing the untriaged pile is `/triage-issues`; this
command starts where that one stops. Follow CLAUDE.md (test-first;
assign `wintermeyer` as a soft lock BEFORE work starts; `mix precommit` green
before every push; bump the `mix.exs` version; authorship footer under every
GitHub text written in my name, in the language of the thread).

Talk to me in the language I write to you (German by default). Write GitHub texts
(issue edits, comments, PR bodies) in the language of the issue itself.

## How you discuss issues with me
This is a conversation, not silent processing. For every issue, tell me briefly
**what you think of it** — worth doing or not, priority, rough effort, risk,
possible duplicate. And ask me about anything that is **unclear** or that **I
have to decide** (scope, product decision, design alternatives, bug vs. feature).
With every question, always include a **solid, reasoned recommendation** so I
only have to agree or correct.

**One issue at a time — this is the core of the flow.** Never dump the whole
backlog, and never ask about several issues in one question; that does not scale.
Present exactly ONE issue (compact summary + the options for it), ask **only
about that one issue** in a single question, wait for my answer, act, then move
to the next. A short count of what lies ahead is fine; the full enumerated list
is not.

## Parallel operation — soft lock (several Claude instances at once)
I may run `/issues` in several instances in parallel. So they don't step on each
other, every instance writes a lock into the issue.

**Instance ID:** Right at the start, generate ONE ID of the form `<epoch>-<rand>`,
where `<epoch>` = `date +%s` (seconds, the lock's creation timestamp) and
`<rand>` = `$RANDOM`, e.g. `1753372800-24917`. Show it to me. **Remember the
concrete value** and put it LITERALLY into every later command — shell variables
do not survive between two Bash calls. Your lock label is `wip:<ID>`; the
`<epoch>` part doubles as the TTL timestamp (below).

**Locked** means an issue carrying a foreign `wip:<epoch>-*` label whose
`<epoch>` is **younger than 6 hours**. You do not touch those; you only show them
under "🔒 other instance". A foreign lock with `<epoch>` **older than 6 h is
expired** and does NOT lock (see "Expired locks").

**Claim** — before you WRITE to an issue (fix, comment, close, snooze);
plain viewing/presenting needs no lock:
1. `gh issue view N --json labels` — does it already carry a foreign `wip:*`?
   Then it's taken: tell me and move on.
2. `gh label create "wip:<ID>" --color 5319e7 --force`, then
   `gh issue edit N --add-label "wip:<ID>" --add-label "in progress"`.
3. **Race check:** `gh issue view N --json labels` again. If there are now
   SEVERAL `wip:*`, the lexicographically SMALLEST ID wins. If you are not the
   smallest → `gh issue edit N --remove-label "wip:<ID>"`, tell me, move on.
   Otherwise you hold the lock.

**Release:** After quick write actions (comment, snooze) you release
the lock IMMEDIATELY; for a fix you hold it until the merge. Release with
`gh issue edit N --remove-label "wip:<ID>" --remove-label "in progress"`. (A
merged fix closes the issue anyway.) If I say "skip" after you already claimed,
release too.

**Clean up the label definition:** whenever you remove a `wip:<...>` label (on
release, on the race back-off, on `unlock`, or on an expired takeover) and no
open issue still carries it, also delete the label itself
(`gh label delete "wip:<...>" --yes`) so `wip:*` labels don't pile up in the
repo's label list.

**Expired locks (TTL 6 h):** Compare a foreign lock's `<epoch>` with now
(`date +%s`): if `now − epoch > 21600` (6 h) the lock is orphaned, a crashed or
forgotten instance. You may then take the issue over: first remove the expired
foreign label (`gh issue edit N --remove-label "wip:<oldvalue>"`), then the
normal claim + race check with your ID. Fresh foreign locks (≤ 6 h) you always
respect.

This is a cooperative lock, not a hard guarantee: the narrow claim window is
resolved deterministically by the race check + smallest-ID rule, and orphaned
locks clear themselves via the 6 h TTL.

## Merge policy (set for this session)
Fix approved → sub-agent in its own worktree, `mix precommit` must be green.
Green → create the PR AND merge it automatically (`--squash --delete-branch`),
without asking. Ask me ONLY on problems: red tests, merge conflict, unclear
requirement, needed product decision, or a migration that isn't N-1 compatible
(CLAUDE.md). A merge to `main` = auto-deploy to production, so never merge with a
red precommit.

## Branch cleanup (after every merge — not optional)
`--squash --delete-branch` reliably deletes the **remote** branch but routinely
leaves the **local** one behind, so a session that merges several issues leaks a
branch per issue (16 had piled up by 2026-07-26). The squash is the cause: it
replays the work as one new commit, so the branch tip never becomes an ancestor
of `main` and git's safe delete refuses it with *"the branch is not fully
merged"*. Force is right here — the PR is merged, the content is on `main`:

```bash
git checkout main && git pull --ff-only
git branch -D <branch>
git fetch --prune origin
```

Since the fix flow dispatches each agent with `isolation: "worktree"`, the branch
is checked out in that worktree and git refuses to delete a branch checked out
anywhere — so **tear the worktree down** (`ExitWorktree`, or `git worktree remove
<path>`) and the branch goes with it. Before reporting, `git branch -vv` must show
no branch marked `[origin/<name>: gone]`; that marker is the signature of this
leak.

---

## Dispatch

`locks` → `gh issue list --state open --json number,title,labels`, filter issues
with `wip:*`, show number, title and the holding ID; mark locks whose `<epoch>`
is older than 6 h as "(expired, treated as free)". Nothing else.

`unlock <issue#>` → show me the `wip:*`/`in progress` labels of N, quick
confirmation, then remove them (`gh issue edit N --remove-label ...`). For the
immediate case; otherwise a lock expires on its own after 6 h.

a bare issue number → skip triage, `gh issue view N --comments`, plan mode, cut
it against the code, get my OK before you write any code.

`stop` / `drain` / `abbrechen` (a dispatch arg **or** me just saying it mid-walk,
in any language: "stop", "abbrechen", "abort", "drain", "genug für heute") →
**graceful stop**, see "Graceful stop (drain)" below.

no argument → the full flow below (generate the instance ID first).

## Phase 0 — scope (counts only, no list dump)
`gh issue list --state open --limit 100 --json number,title,labels,assignees,author`.
Internally: set aside issues with a foreign, **non-expired** (`<epoch>` ≤ 6 h
old) `wip:*` label. Then tell me only the **counts** — how many bugs, how many
feature requests (plus one line if something is locked by another instance). Do
**not** enumerate the backlog. Go straight into the per-issue walk below.

**You work labelled issues only.** An issue carrying neither `Bug` nor
`Feature Request` is untriaged and not yours: count them in one line ("44
uncategorized, run `/triage-issues`") and never categorize one yourself, not
even in passing mid-walk. Same for the snooze wake pass: `/triage-issues`
owns it, so a snoozed issue simply does not appear here until it wakes.

## Phase 1 — walk the bugs (issue by issue)
`gh issue list --state open --label Bug --json number,title,author` (foreign-
locked ones skipped). For each bug individually, wait for me after each:
1. **Show the issue** (`gh issue view N --comments`), explain cause/context and
   tell me **what you think of it** (worth fixing, effort, risk, duplicate).
2. **Discussion overview:** only if the issue has comments, summarize the
   thread — who said what, which questions are open. No comments → skip this
   entirely, show nothing about a discussion.
3. **Ask what should happen** (with a recommendation):
   - **Fix** → "Fix flow" below.
   - **Ask the author** → "Ask the author" below.
   - **Reject / decline** → "Reject / decline" below.
   - **Snooze** → "Snooze" below.
   - **Skip** → next bug (release any held lock).

## Phase 2 — walk the feature requests
`gh issue list --state open --label "Feature Request" --json number,title,author`.
Like Phase 1, "Fix" here means "implement". For features, more often clarify the
scope first (ask the author / plan mode) before code appears. Name dependencies
(e.g. the Fediverse cluster #986/#985/#911/#910/#784 = one milestone).

---

## Fix flow (bug/feature approved)
1. **Claim** (soft lock) — lost it? Another instance is on it, tell me.
2. `gh issue edit N --add-assignee wintermeyer` (CLAUDE.md soft lock, BEFORE work).
3. Dispatch **one sub-agent with `isolation: "worktree"`**. Task: implement issue
   #N, strictly per CLAUDE.md — first a failing test, then the fix, `mix
   precommit` green, bump `mix.exs`, push the branch, open the PR (body +
   authorship footer). Report back: PR number, precommit result, short summary.
4. **precommit green?** Yes → `gh pr merge <nr> --squash --delete-branch`, then
   clean up locally (see **Branch cleanup** below — `--delete-branch` leaves the
   local branch behind after a squash merge), then **release** the lock; show me
   the PR link + one sentence. No/conflict/unclear → do NOT merge, hold the lock,
   put the problem to me and ask.
5. **The merge auto-closes the issue, so the note is on you.** Draft the shipped
   note per CLAUDE.md's issue-close rule, case (a) — what now works, the version,
   and why I built it this way. Show me the draft, get my OK, then
   `gh issue comment N --body "..."` (a closed issue still takes comments, so
   posting after the merge is fine). Skip only for an issue I filed myself.

## Ask the author (question back on the issue)
Always offer this as an option. Get the author (`gh issue view N --json author`).
Draft a friendly question in the first person, in the language of the issue, with
the authorship footer (CLAUDE.md). Show me the draft, get my OK, then (after
**claim**) `gh issue comment N --body "..."`, then **release**.

## Reject / decline (close without doing it)
Always offer this as an option in every per-issue walk. When I decide an issue
won't be done — out of scope, won't fix, a design we don't want, a duplicate
we're closing — you close it **kindly**, never let it rot. First **ask me for the
reason** in the same question (offer a short, reasoned recommendation; the reason
may also be "none / just decline"), then, after **claim**:
1. Get the author (`gh issue view N --json author`) and draft the closing note per
   CLAUDE.md's issue-close rule, case (b) — or case (c) when the close is simply
   my call rather than a judgement on the merits. Show me the draft, get my OK.
2. `gh issue comment N --body "..."` (post the note), then close:
   `gh issue close N --reason "not planned"` (use `--reason completed` only when
   it's genuinely resolved another way).
3. **Release** the lock: remove the `wip:*` / `in progress` labels and clean up
   the label definition (a closed issue keeps no lock).

## Graceful stop (drain)
I can end the walk at any time — a `stop`/`drain`/`abbrechen` dispatch arg, or me
just saying so mid-flow. **Do not treat this as an emergency kill.** The rule:
**finish the work already in flight, touch no new issue.**
1. **Stop starting new work immediately.** Present, claim, comment,
   snooze, or dispatch NOTHING new. The per-issue walk ends here — do not move to
   the next issue.
2. **Let in-flight FIX AGENTS finish.** Any sub-agent already running keeps going;
   when it reports, apply the normal merge policy (green → `--squash
   --delete-branch` + the **Branch cleanup** below, then **release** that issue's
   lock; red/conflict/unclear → hold the lock and tell me). Keep watching CI for a
   PR that is mid-merge.
3. **Queued-but-not-started items** (claimed + assigned, but no agent dispatched
   yet): these count as "not started". List them and **ask me once** whether to
   keep them claimed for a later `/issues` run or release them now (release =
   remove `wip:*` + `in progress` labels, keep the `wintermeyer` assignee as the
   soft lock, then clean up the label definition per the rules). Default
   recommendation: release the locks so they don't look actively worked on, but
   keep the assignee.
4. **Final summary.** Report what merged/shipped this session, what is still
   draining (agent still running / PR mid-merge), and what was left untouched.
   Then stop — no further issues until I run `/issues` again.
Locks I still hold for a draining fix stay until that fix merges (or I explicitly
release it); everything else is released per the normal rules.

## Snooze (deal with it later)
Labels `snoozed` + `snooze:YYYY-MM-DD` (name = wake date). Compute the date from
today (macOS: `date -v+1w +%F`, `date -v+1m +%F`; an explicit `YYYY-MM-DD`
verbatim). After **claim**: `gh label create snoozed --color c5def5 --force`,
`gh label create "snooze:<date>" --color ededed --force`,
`gh issue edit N --add-label snoozed --add-label "snooze:<date>"`, then
**release**. The **wake pass** lives in `/triage-issues`, not here: a snoozed
issue is out of this walk until that command wakes it.
