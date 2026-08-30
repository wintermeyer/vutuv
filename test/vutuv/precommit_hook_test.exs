defmodule Vutuv.PrecommitHookTest do
  @moduledoc """
  `.claude/hooks/precommit-before-push.sh` is the last automatic gate before a
  push, and a push to `main` auto-deploys to production. It shipped with two
  defects that this covers (both found 2026-08-02):

    * it ran `mix precommit` in `$CLAUDE_PROJECT_DIR` rather than in the
      worktree the push came from, so with several worktrees on one repository
      it could report green for code it had never compiled;
    * it recognised a push by the substring `"git push"`, which blocked a plain
      `grep "git push"` and, far worse, missed `git -C <dir> push` entirely.

  The three shapes asserted here are the ones a guard like this fails in:
  the exemption belonging to a *different* unit of the command line, the
  forbidden effect spelled a way the rule does not literally name, and a
  degraded path (missing dependency, unresolvable directory) that must fail
  closed rather than wave the push through.

  A third defect is the opposite failure — the gate charging a push for an
  answer it cannot give. Its whole cost is the ~9,100-test suite, and none of
  precommit's five steps reads a `docs/` page or a top-level Markdown file, so
  #1774 paid ~300-900 s nine times over for one Markdown file. The exemption
  that fixes it is calibrated here from both sides: without it the `SKIP` cases
  go red, and widening it to "anything ending in `.md`" reds the two that pin a
  build-input Markdown file to the full gate. The `mix.exs` case is the one no
  widening of the Markdown rule can red, because `mix.exs` is not Markdown; it
  guards a different edit, somebody exempting `mix.*` or `*.exs` outright.

  Which base that diff is read from is the whole of the exemption's worth, and
  the hook says why. The cases that pin it are the three that give the branch a
  tracking ref at all: two under "a branch that has caught up with main", and
  the `tracking: true` degraded path, which is the one shape where the tracking
  ref would answer and must still not be asked.

  The hook's `--explain` mode prints its decision without running precommit;
  that mode exists for this test, and the settings.json invocation passes no
  arguments so it can never be reached in normal use.
  """
  use ExUnit.Case, async: true

  @hook ".claude/hooks/precommit-before-push.sh"

  setup do
    root = File.cwd!()
    {:ok, root: root, hook: Path.join(root, @hook)}
  end

  describe "commands that are not a push" do
    test "an ordinary command is allowed", ctx do
      assert decide(ctx, "echo hello") == "ALLOW"
    end

    test "a command that merely mentions the words is allowed", ctx do
      # The exemption belongs to a different unit: `git push` appears as grep's
      # argument, not as the command being run. The substring match blocked this.
      assert decide(ctx, ~s{grep -rn "git push" .claude/}) == "ALLOW"
      assert decide(ctx, ~s{echo "run git push when done"}) == "ALLOW"
    end

    test "other git subcommands are allowed", ctx do
      assert decide(ctx, "git status") == "ALLOW"
      assert decide(ctx, "git log --oneline") == "ALLOW"
      assert decide(ctx, "git log --grep push") == "ALLOW"
    end
  end

  describe "pushes, however they are spelled" do
    test "a plain push resolves to the tool call's own directory", ctx do
      assert decide(ctx, "git push") == "PUSH #{ctx.root}"
      assert decide(ctx, "git push origin main") == "PUSH #{ctx.root}"
    end

    test "`git -C <dir> push` is a push and names its own tree", ctx do
      # The spelling the old substring rule could not see at all.
      assert decide(ctx, "git -C #{ctx.root} push") == "PUSH #{ctx.root}"
      assert decide(ctx, "git -C#{ctx.root} push origin HEAD") == "PUSH #{ctx.root}"
    end

    test "a push behind a chain operator is still a push", ctx do
      assert decide(ctx, "mix test && git push") == "PUSH #{ctx.root}"
      assert decide(ctx, "echo one; git push") == "PUSH #{ctx.root}"
    end

    test "a leading cd governs the push that follows it", ctx do
      assert decide(ctx, "cd #{ctx.root} && git push") == "PUSH #{ctx.root}"
    end

    test "environment assignments before git do not hide the push", ctx do
      assert decide(ctx, "GIT_TRACE=1 git push") == "PUSH #{ctx.root}"
    end

    test "global options that swallow a word do not hide the push", ctx do
      assert decide(ctx, "git -c user.name=x push") == "PUSH #{ctx.root}"
    end
  end

  describe "degraded paths fail closed" do
    test "an unresolvable working directory blocks instead of allowing", ctx do
      decision = decide(ctx, "git push", cwd: "/nonexistent/worktree")

      assert decision =~ "BLOCK",
             "a push whose tree cannot be resolved must be blocked, got: #{decision}"

      assert decision =~ "cannot tell which git worktree"
    end

    test "a push from a tree that is not the project blocks", ctx do
      # Resolvable as a git repo is not enough — it must be the vutuv checkout,
      # or precommit would vouch for the wrong thing. This repository has no
      # remote, so it is also the degraded path of the wiki exemption below:
      # an unreadable remote is an unanswered question, not an exemption.
      tmp = tmp_repo()

      decision = decide(ctx, "git -C #{tmp} push")

      assert decision =~ "BLOCK", "expected a block, got: #{decision}"
      assert decision =~ "not the vutuv project root"
    end

    test "without jq a push is refused rather than waved through", ctx do
      # The dependency this hook reads its input with, removed. Silence must
      # mean "block", never "allow".
      path = path_without_jq()

      assert decide(ctx, "git push", path: path) =~ "BLOCK"
      assert decide(ctx, "git push", path: path) =~ "jq"
      # A harmless command still gets through, so a missing jq does not brick
      # every Bash call in the session.
      assert decide(ctx, "echo hello", path: path) == "ALLOW"
    end
  end

  describe "the wiki exemption" do
    # A GitHub wiki lives in a repository of its own (`<repo>.wiki.git`): no
    # mix.exs, no suite, no deploy, so precommit has nothing to vouch for and
    # the gate would make a wiki page unpublishable. The exemption is scoped to
    # that one shape, and every other reading of it still blocks.
    test "a push from a wiki clone is allowed, ssh or https", ctx do
      ssh = tmp_repo(remote: "git@github.com:wintermeyer/vutuv.wiki.git")
      https = tmp_repo(remote: "https://github.com/wintermeyer/vutuv.wiki.git")

      assert decide(ctx, "git -C #{ssh} push origin master") == "ALLOW"
      assert decide(ctx, "git -C #{https} push") == "ALLOW"
    end

    test "a remote that only looks like one still blocks", ctx do
      # Calibration against a false positive: the URL has to *end* in
      # `.wiki.git`, not merely mention it. The repository with no remote at
      # all is the test above this describe block.
      backup = tmp_repo(remote: "git@github.com:wintermeyer/vutuv.wiki.git.backup")
      foreign = tmp_repo(remote: "git@github.com:someone/something.git")

      decision = decide(ctx, "git -C #{backup} push")

      assert decision =~ "BLOCK", "expected a block, got: #{decision}"
      assert decision =~ "not the vutuv project root"
      assert decide(ctx, "git -C #{foreign} push") =~ "BLOCK"
    end
  end

  describe "the documentation exemption" do
    # `mix precommit`'s cost is its ~9,100-test suite, and none of its five
    # steps can read a `docs/` page, a `.github/` workflow or a top-level
    # Markdown file. A push carrying only those buys an answer about code it
    # never touched — #1774 paid that run nine times for one Markdown file.
    test "a push carrying only documentation skips the run", ctx do
      repo =
        tmp_project(["CONTRIBUTING.md", "docs/architecture/feed.md", ".github/workflows/ci.yml"])

      decision = decide(ctx, "git -C #{repo} push")

      assert decision =~ "SKIP", "expected a skip, got: #{decision}"
      assert decision =~ "CI still checks everything"
    end

    test "one file precommit can read pays the whole gate", ctx do
      # The mixed push is the case worth pinning: the docs do not dilute the
      # source file beside them.
      repo = tmp_project(["CONTRIBUTING.md", "lib/vutuv/thing.ex"])

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end

    test "a change to mix.exs is not documentation", ctx do
      # `mix.exs` is compiled and format-checked, and it decides what the suite
      # builds at all, so any push touching it still pays the full gate.
      repo = tmp_project(["mix.exs"])

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end

    test "Markdown the build reads is not documentation", ctx do
      # The reason the rule is deny-first rather than extension-first:
      # `priv/help/*.md` compiles into `HelpController`, `priv/dev_docs/*.md`
      # into `DevDocController`, `.claude/rules/design.md` is read and asserted
      # on by the dark-mode tests, and `rel/` holds the release templates the
      # deploy builds from.
      for path <- [".claude/rules/design.md", "priv/help/imprint_en.md", "rel/overlays/notes.md"] do
        repo = tmp_project([path])

        assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}",
               "#{path} is a build input, not documentation"
      end
    end

    test "only top-level Markdown is documentation", ctx do
      # In a `case` pattern `*` matches `/` too, so a bare `*.md` arm exempts
      # Markdown at any depth — a directory nobody has denied yet would have
      # skipped the gate the day it was added. Only the named directories are
      # exempt at depth; anything else has to sit at the top.
      nested = tmp_project(["content/posts/hello.md"])
      top = tmp_project(["CONTRIBUTING.md"])

      assert decide(ctx, "git -C #{nested} push") == "PUSH #{nested}"
      assert decide(ctx, "git -C #{top} push") =~ "SKIP"
      # A named directory still is exempt at any depth.
      deep = tmp_project(["docs/architecture/a/b/c.md"])
      assert decide(ctx, "git -C #{deep} push") =~ "SKIP"
    end
  end

  describe "a branch that has caught up with main" do
    # A documentation PR lives long enough that main moves under it, so from
    # its second push onwards the branch has merged main in or been rebased
    # onto it. Both shapes carry `lib/vutuv/thing.ex` when the diff is read
    # from the tracking ref and only the Markdown file when it is read from the
    # trunk, which is the difference the hook's base comment is about.
    test "a branch that merged main in still skips", ctx do
      repo = tmp_project(["CONTRIBUTING.md"], integrate: :merge)

      assert decide(ctx, "git -C #{repo} push") =~ "SKIP"
    end

    # The same assertion through a rewritten history rather than a merge
    # commit, which is what would catch a base read off the top commit alone.
    test "a branch rebased onto main still skips", ctx do
      repo = tmp_project(["CONTRIBUTING.md"], integrate: :rebase)

      assert decide(ctx, "git -C #{repo} push --force-with-lease") =~ "SKIP"
    end
  end

  describe "the exemption's degraded paths" do
    # Rule 1 of the hook: an unanswered question is not an exemption. Each of
    # these carries documentation only, and each must still run the gate
    # because the hook cannot prove what the push would put on the remote.
    test "a push naming another ref pays the gate", ctx do
      repo = tmp_project(["CONTRIBUTING.md"])

      assert decide(ctx, "git -C #{repo} push origin main") == "PUSH #{repo}"
      assert decide(ctx, "git -C #{repo} push --all") == "PUSH #{repo}"
      # Spelled as this branch, it is the same push and still skips.
      assert decide(ctx, "git -C #{repo} push origin HEAD") =~ "SKIP"
    end

    test "a detached HEAD pays the gate", ctx do
      repo = tmp_project(["CONTRIBUTING.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "--quiet", "--detach"])

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end

    test "no merge base to compare against pays the gate", ctx do
      repo = tmp_project(["CONTRIBUTING.md"], trunk: false)

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end

    test "a tracking ref is no substitute for the trunk", ctx do
      # The one shape where a second base would answer: no trunk ref, but a
      # tracking ref whose merge base yields the documentation file on its own.
      # The hook does not ask it. That reading is the permissive one, and an
      # unanswered question is not an exemption.
      repo = tmp_project(["CONTRIBUTING.md"], trunk: false, tracking: true)

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end
  end

  # Runs the hook in `--explain` mode against a payload and returns its verdict.
  # `System.cmd/3` cannot feed stdin, so the payload goes in through a file
  # redirect run by `sh`.
  defp decide(ctx, command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ctx.root)
    payload = Jason.encode!(%{"cwd" => cwd, "tool_input" => %{"command" => command}})

    payload_file =
      Path.join(
        System.tmp_dir!(),
        "precommit-hook-payload-#{System.unique_integer([:positive])}.json"
      )

    File.write!(payload_file, payload)
    on_exit(fn -> File.rm(payload_file) end)

    env =
      case Keyword.fetch(opts, :path) do
        {:ok, path} -> [{"PATH", path}]
        :error -> []
      end

    script = "bash #{shell_quote(ctx.hook)} --explain < #{shell_quote(payload_file)}"

    {out, _status} =
      System.cmd("sh", ["-c", script], cd: ctx.root, env: env, stderr_to_stdout: true)

    String.trim(out)
  end

  # A throwaway git repository, optionally carrying an `origin` remote.
  defp tmp_repo(opts \\ []) do
    tmp =
      System.tmp_dir!()
      |> Path.join("precommit-hook-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {_, 0} = System.cmd("git", ["init", "--quiet", tmp])

    case Keyword.fetch(opts, :remote) do
      {:ok, url} ->
        {_, 0} = System.cmd("git", ["-C", tmp, "remote", "add", "origin", url])

      :error ->
        :ok
    end

    tmp
  end

  # A throwaway repository shaped like the vutuv checkout: a `mix.exs` on a base
  # commit registered as `upstream/main`, then one commit on branch `work`
  # touching `paths`. That second commit is what a push from it would carry.
  # `trunk: false` leaves the trunk ref out, so nothing can be compared.
  # `tracking: true` gives the branch a tracking ref at the base commit, and
  # `integrate: :merge | :rebase` ages it instead: it is pushed once, main
  # gains a source file, and the branch takes that in the two ways a long-lived
  # PR does.
  defp tmp_project(paths, opts \\ []) do
    repo = tmp_repo()
    git = fn args -> {_, 0} = System.cmd("git", ["-C", repo | args]) end

    git.(["config", "user.email", "hook-test@example.com"])
    git.(["config", "user.name", "Hook Test"])
    git.(["config", "commit.gpgsign", "false"])

    File.write!(Path.join(repo, "mix.exs"), "# base\n")
    git.(["add", "-A"])
    git.(["commit", "--quiet", "-m", "base"])
    git.(["branch", "-M", "work"])

    if Keyword.get(opts, :trunk, true),
      do: git.(["update-ref", "refs/remotes/upstream/main", "HEAD"])

    if Keyword.get(opts, :tracking, false), do: track(repo, git)

    for path <- paths do
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "changed by #{inspect(self())}\n")
    end

    git.(["add", "-A"])
    git.(["commit", "--quiet", "-m", "work"])

    case Keyword.fetch(opts, :integrate) do
      {:ok, how} -> integrate(repo, git, how)
      :error -> :ok
    end

    # The hook reports the resolved toplevel, and on macOS the temp directory
    # reaches it through the `/var` → `/private/var` symlink.
    {toplevel, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"])
    String.trim(toplevel)
  end

  # The branch gets a tracking ref at the current HEAD. The remote entry is not
  # decoration: `@{upstream}` resolves through its fetch refspec and NOT through
  # `branch.work.merge` alone, so without it git answers nothing, and a fixture
  # built to tell two bases apart quietly stops telling them apart. Nothing ever
  # contacts the address.
  defp track(repo, git) do
    git.(["remote", "add", "origin", Path.join(repo, "origin.git")])
    git.(["update-ref", "refs/remotes/origin/work", "HEAD"])
    git.(["branch", "--quiet", "--set-upstream-to=origin/work", "work"])
  end

  # The branch has been pushed once, and main has moved since. The tracking ref
  # stays at the tip that was pushed, which is the whole point: once the branch
  # takes main's commit in, that ref sits *behind* the integration and its merge
  # base drags main's source file into the branch's diff. The trunk ref moves
  # with main, so the merge base with it does not.
  defp integrate(repo, git, how) do
    track(repo, git)

    git.(["checkout", "--quiet", "--detach", "refs/remotes/upstream/main"])
    File.mkdir_p!(Path.join(repo, "lib/vutuv"))
    File.write!(Path.join(repo, "lib/vutuv/thing.ex"), "# moved on\n")
    git.(["add", "-A"])
    git.(["commit", "--quiet", "-m", "main moved on"])
    git.(["update-ref", "refs/remotes/upstream/main", "HEAD"])
    git.(["checkout", "--quiet", "work"])

    case how do
      :merge -> git.(["merge", "--quiet", "--no-edit", "refs/remotes/upstream/main"])
      :rebase -> git.(["rebase", "--quiet", "refs/remotes/upstream/main"])
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", ~S('\'')) <> "'"

  # A PATH holding every binary the hook needs except `jq`.
  defp path_without_jq do
    dir =
      Path.join(
        System.tmp_dir!(),
        "precommit-hook-nojq-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for tool <- ~w(bash sh awk git cat sed grep env) do
      case System.find_executable(tool) do
        nil -> :ok
        path -> File.ln_s!(path, Path.join(dir, tool))
      end
    end

    dir
  end
end
