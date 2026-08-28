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
  that fixes it is calibrated here from both sides: without it the two `SKIP`
  cases go red, and widening it to "anything ending in `.md`" reds the two that
  pin `mix.exs` and a build-input Markdown file to the full gate.

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

    test "a version bump is not documentation", ctx do
      # `mix.exs` is compiled, formatted and asserted on by `BumpVersionTest`,
      # so a PR branch carrying its own bump still pays the full gate.
      repo = tmp_project(["mix.exs"])

      assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}"
    end

    test "Markdown the build reads is not documentation", ctx do
      # The reason the rule is deny-first rather than extension-first:
      # `priv/help/*.md` compiles into `HelpController`, `priv/dev_docs/*.md`
      # into `DevDocController`, and `.claude/rules/design.md` is read and
      # asserted on by the dark-mode tests.
      for path <- [".claude/rules/design.md", "priv/help/imprint_en.md"] do
        repo = tmp_project([path])

        assert decide(ctx, "git -C #{repo} push") == "PUSH #{repo}",
               "#{path} is a build input, not documentation"
      end
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

    if Keyword.get(opts, :trunk, true) do
      {head, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
      git.(["update-ref", "refs/remotes/upstream/main", String.trim(head)])
    end

    for path <- paths do
      full = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "changed by #{inspect(self())}\n")
    end

    git.(["add", "-A"])
    git.(["commit", "--quiet", "-m", "work"])

    # The hook reports the resolved toplevel, and on macOS the temp directory
    # reaches it through the `/var` → `/private/var` symlink.
    {toplevel, 0} = System.cmd("git", ["-C", repo, "rev-parse", "--show-toplevel"])
    String.trim(toplevel)
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
