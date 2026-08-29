---
name: deploy
description: "vutuv deploy: never push to main directly. Branch → mix precommit green → PR → wait for CI green → squash-merge. The merge to main is what triggers the production deploy."
argument-hint: "[message]"
allowed-tools: Bash, Read, Grep, Glob, Agent
---

# Deploy Skill (vutuv)

**In this repository `/deploy` means: open a pull request, wait for CI to go
green, then merge it.** It never means "commit and push to `main`". A push to
`main` fires `.github/workflows/deploy.yml` and deploys to production
immediately, so `main` is reached only through a merged, CI-green PR — the merge
commit is the deploy trigger.

This project skill overrides the personal `deploy` skill in
`~/.claude/skills/deploy/`. When both are offered, use this one.

**Token/latency discipline.** The expensive part is `mix precommit` over the
test suite, and the naive loop ingests its full output once per iteration:

- **Never stream a check's output into context. Redirect it to a log and judge
  it by the command's own exit code.** On a green run that is ~5 tokens instead
  of thousands. Read the log only when the exit code is non-zero, and then only
  the failing part.
- **Iterate cheap, gate once.** When something fails, re-run only the failing
  thing to confirm each fix; run the full `mix precommit` exactly once, at the
  end, as the final gate.

## Steps

1. **Get onto a branch.** `git status --short --branch`.
   - On a feature branch already → keep it.
   - On `main` → create one from the current work (`git switch -c <topic>`,
     a short kebab-case name describing the change). Never commit on `main`.

2. **First precommit run (redirected, exit-code only).**

   ```bash
   mix precommit > precommit.log 2>&1
   ```

   Judge it **by this command's own exit code**. Do NOT append `; echo "EXIT=$?"`
   and do NOT pipe into `tail`/`grep`: that makes the shell report the *last*
   command's code (always 0) and silently masks a red precommit.

   - **Exit 0** → step 4. Do not read the log; it passed.
   - **Non-zero** → step 3. Do **not** read the whole log into the main thread.

3. **Fix the failures in a subagent (only when step 2 was red).** Launch a
   `general-purpose` subagent with the Agent tool and this brief:

   > `mix precommit` failed; its output is in `precommit.log` at the repo root.
   > Make it pass. Rules:
   > - Fix ALL reported issues, even ones unrelated to the current work
   >   (compiler warnings-as-errors, `mix format`, `credo --strict`, tests).
   >   For formatting, just run `mix format` — don't hand-edit whitespace.
   > - **Iterate cheap:** confirm each fix by re-running only the failing
   >   thing — `mix test --failed`, or `mix test path/to/file.exs:LINE`, or
   >   `mix credo --strict path` — always redirected to a log and judged by
   >   exit code, never streamed.
   > - **Gate once:** when you believe it's green, run the full alias one final
   >   time as `mix precommit > precommit.log 2>&1` (no trailing `echo`, no
   >   pipe) and judge it by that command's own exit code. It must exit 0.
   > - Report back in a few lines: what was broken, what you changed, and the
   >   final exit code of the full `mix precommit`. Do not paste test output.

   Do not proceed unless the subagent reports the full `mix precommit` exited 0.
   If it can't get to green, stop and tell the user what's still failing.

4. **Check the working tree** — `git status --short` and `git diff --stat` to see
   everything that changed (your work + any subagent fixes). There is **no
   version to bump**: `mix.exs` derives it from the commit date at build time,
   and the footer names the commit itself (`Vutuv.BuildInfo`).

5. **Note the deploy strategy** for the PR body — a **cold deploy** is needed
   when any of these apply, otherwise it's a hot deploy:
   - New or changed Ecto migrations (`priv/repo/migrations/`)
   - Changes to supervision trees, GenServers, or application startup
   - Changes to `config/runtime.exs` / `config/prod.exs`
   - Changes to `mix.exs` dependencies
   - The user explicitly asked for a cold deploy

   Migrations also need the N-1 backward-compatibility check from `CLAUDE.md`
   (blue/green: the *previous* release keeps serving the migrated schema).

6. **Commit** — a short summary line, a blank line, then a body explaining *why*
   (motivation, context, trade-offs), per Stefan's commit rule. `gh pr merge
   --squash` takes a single-commit PR's subject, not the PR title, so write the
   subject as you want it in `main`'s log. If cold deploy, append
   `[cold-deploy]` to the summary line. If the user passed `$ARGUMENTS`, use it
   as the basis. End the body with the plain-paragraph agent-authorship footer.
   Stage specific paths, never secrets (`.env`, credentials).

7. **Push the branch — in a Bash call of its own.** The `PreToolUse` hook
   `.claude/hooks/precommit-before-push.sh` intercepts any Bash command
   containing `git push` and runs the full precommit again, aborting the *whole*
   command on failure. So never chain (`git push && gh pr create …`): the chained
   command dies with the push. One call, one push:

   ```bash
   git push -u origin HEAD
   ```

8. **Open the PR.** Body: what changed and why, hot vs cold deploy, plus the
   agent-authorship footer in italics.

   ```bash
   gh pr create --fill-first --title "…" --body "…"
   ```

9. **Wait for CI to go green** — this is the point of the whole flow, so
   actually wait, don't fire and forget:

   ```bash
   gh pr checks --watch --fail-fast
   ```

   - **Green** → step 10.
   - **Red** → do NOT merge. Fix it (subagent as in step 3 if noisy), push the
     fix to the branch, and watch again. If it stays red or the failure isn't
     yours to fix, stop and report; leave the PR open.

10. **Merge** — squash and delete the branch (the repo convention, same as
    `/issues`):

    ```bash
    gh pr merge <nr> --squash --delete-branch
    ```

    Another PR can merge while yours sits in CI; that only matters when the two
    touched the same lines, and then GitHub says `CONFLICTING` (`gh pr view
    <nr> --json mergeable`). Rebase onto `origin/main`, re-run `mix precommit`,
    push with `--force-with-lease`, watch CI again, and only then merge.

    The merge lands on `main` and that push is what starts
    `.github/workflows/deploy.yml`.

11. **Delete the local branch by force, then prune** — `--delete-branch` reliably
    removes the *remote* branch but routinely leaves the local one behind, so
    without this step every deploy leaks a branch (16 had piled up by
    2026-07-26). The cause is the **squash** merge: it replays your work as one
    new commit, so your branch tip never becomes an ancestor of `main` and git's
    safe delete refuses it with *"the branch is not fully merged"*. Force is
    correct here and not a risk — the PR is merged, so the content is on `main`.

    ```bash
    git checkout main && git pull --ff-only
    git branch -D <branch>
    git fetch --prune origin
    ```

    Run it from the checkout that owns the branch. In a **worktree** session the
    branch is checked out there, and git refuses to delete a branch checked out
    anywhere — so tear the worktree down instead (`ExitWorktree`, or
    `git worktree remove <path>`), which drops the branch with it.

12. **Verify nothing leaked** — `git branch -vv` must show no branch marked
    `[origin/<name>: gone]`. A `gone` marker is the signature of this leak: the
    remote branch was deleted, the local one survived.

13. **Report** — one short summary: PR link, hot vs cold, CI green, merged,
    and (if step 3 ran) a one-line note that precommit failures were fixed.
    Optionally confirm the deploy started
    (`gh run list --workflow=deploy.yml --limit 1`). Do not paste command output.

## When the user really wants a direct push

Only on an explicit, unambiguous instruction for that specific push ("push
straight to main", "skip the PR"). Say once that it bypasses CI-before-deploy,
then do it. A plain `/deploy` is never that instruction.
