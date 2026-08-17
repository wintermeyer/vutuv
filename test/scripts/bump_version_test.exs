defmodule Scripts.BumpVersionTest do
  @moduledoc """
  `scripts/bump_version.exs` picks the next version number, and the thing it has
  to get right is not the arithmetic but the **claims**: an open pull request
  holds its number in its own `mix.exs` for hours before it merges, so `main`
  still looks free and two branches pick the same one. That produces no merge
  conflict and no warning (both sides write the same line), so the collision is
  only noticed afterwards, when one number names two changes.

  Not async: each test runs the script in its own temp directory, but they share
  the `PATH` a fake `gh` is put on.
  """
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/bump_version.exs", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "bump_version_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_mix(dir, version) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fake.MixProject do
      def project do
        [app: :fake, version: "#{version}"]
      end
    end
    """)
  end

  # A `gh` that answers the two calls the script makes: the open-PR list, and
  # one mix.exs per PR head. `claims` maps a sha to the version that branch
  # carries. `status` non-zero simulates gh failing (unauthenticated, offline).
  defp fake_gh(dir, claims, status \\ 0) do
    listing =
      claims
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{sha, _version}, i} -> "#{1500 + i}\tbranch-#{i}\t#{sha}" end)

    contents =
      Enum.map_join(claims, "\n", fn {sha, version} ->
        encoded = Base.encode64(~s(  version: "#{version}"))
        ~s(    #{sha}) <> ") echo '#{encoded}';;"
      end)

    path = Path.join([dir, "bin", "gh"])

    File.write!(path, """
    #!/bin/bash
    if [ #{status} -ne 0 ]; then echo "stubbed gh failure" >&2; exit #{status}; fi
    case "$1" in
      pr) printf '%s\\n' '#{listing}' ;;
      api)
        ref="${2##*ref=}"
        case "$ref" in
    #{contents}
          *) echo "no such ref" >&2; exit 1;;
        esac
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
    path
  end

  # `claims` opts in to the shared register (the env seam the script reads
  # instead of the git dir); without it the run must behave as if there were
  # none, which is also what a checkout outside any repository gets.
  defp run(dir, level \\ "patch", opts \\ []) do
    env = [
      {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
      {"VUTUV_VERSION_CLAIMS_DIR", opts[:claims]}
    ]

    args = [@script, level] ++ List.wrap(opts[:note])

    {out, status} = System.cmd("elixir", args, cd: dir, env: env, stderr_to_stdout: true)

    version =
      File.read!(Path.join(dir, "mix.exs")) |> then(&Regex.run(~r/"([\d.]+)"/, &1)) |> Enum.at(1)

    %{output: out, status: status, version: version}
  end

  defp claims_dir(dir) do
    path = Path.join(dir, "claims")
    File.mkdir_p!(path)
    path
  end

  defp file_claim(dir, version, branch) do
    File.write!(Path.join(claims_dir(dir), version), """
    branch: #{branch}
    note: irgendwas
    at: 2026-08-17T09:00:00Z
    """)
  end

  # A repository whose current branch has a name, so the script can recognise
  # its own claims. `git init -b` names it without needing a commit.
  defp init_repo(dir, branch) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", branch], cd: dir)

    {_, 0} =
      System.cmd("git", ["commit", "-q", "--allow-empty", "-m", "x"], cd: dir, env: git_env())

    :ok
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@example.com"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@example.com"}
    ]
  end

  test "bumps past the number an open PR already claims", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.1"})

    result = run(dir)

    assert result.status == 0
    # 7.304.1 is taken, so the patch bump has to land on .2 — bumping from the
    # local file alone would have produced the very collision this prevents.
    assert result.version == "7.304.2"
    assert result.output =~ "already claims 7.304.1"
  end

  test "an equal claim is reported too: that is the silent case", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.0"})

    result = run(dir)

    assert result.version == "7.304.1"
    assert result.output =~ "already claims 7.304.0"
  end

  test "a claim below the local number changes nothing", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.300.1"})

    result = run(dir)

    assert result.version == "7.304.1"
    refute result.output =~ "already claims"
  end

  test "minor and major bump from the highest claim as well", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.305.3"})

    assert run(dir, "minor").version == "7.306.0"

    write_mix(dir, "7.304.0")
    assert run(dir, "major").version == "8.0.0"
  end

  # Refusing to bump would block a deploy over a network hiccup, and the
  # fallback is only as wrong as the behaviour before this existed — but it must
  # say so, or a silent fallback reads as "no claims found".
  test "gh failing warns and still bumps from mix.exs", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{"sha1" => "7.304.9"}, 4)

    result = run(dir)

    assert result.status == 0
    assert result.version == "7.304.1"
    assert result.output =~ "could not read the open PRs"
  end

  test "gh missing entirely is the same degraded path", %{dir: dir} do
    write_mix(dir, "7.304.0")

    result = run(dir)

    assert result.status == 0
    assert result.version == "7.304.1"
    assert result.output =~ "could not read the open PRs"
  end

  test "an unknown level fails loudly instead of writing a wrong number", %{dir: dir} do
    write_mix(dir, "7.304.0")
    fake_gh(dir, %{})

    result = run(dir, "huge")

    assert result.status == 1
    assert result.version == "7.304.0"
    assert result.output =~ "unknown level"
  end

  # The shared register (a directory under the common `.git`, so every worktree
  # of one checkout sees it and nothing in it can be committed) closes the gap
  # GitHub cannot: the minutes between bumping and opening the PR.
  describe "the local claims register" do
    test "steps over a number another branch has filed", %{dir: dir} do
      write_mix(dir, "7.304.0")
      fake_gh(dir, %{})
      file_claim(dir, "7.304.1", "somebody-else")

      result = run(dir, "patch", claims: claims_dir(dir))

      assert result.version == "7.304.2"
      assert result.output =~ "somebody-else claims 7.304.1"
    end

    test "files its own claim, note and branch included", %{dir: dir} do
      write_mix(dir, "7.304.0")
      fake_gh(dir, %{})
      init_repo(dir, "meine-arbeit")

      result = run(dir, "patch", claims: claims_dir(dir), note: "Zwei Dinge geradegezogen")

      assert result.version == "7.304.1"
      body = File.read!(Path.join(claims_dir(dir), "7.304.1"))
      assert body =~ "branch: meine-arbeit"
      assert body =~ "note: Zwei Dinge geradegezogen"
    end

    # Otherwise every re-run after a rebase would walk the number up again.
    test "its own branch's claim does not push the number along", %{dir: dir} do
      write_mix(dir, "7.304.0")
      fake_gh(dir, %{})
      init_repo(dir, "meine-arbeit")
      file_claim(dir, "7.304.1", "meine-arbeit")

      result = run(dir, "patch", claims: claims_dir(dir))

      assert result.version == "7.304.1"
    end

    # A claim the released version has reached is spent, and the register must
    # forget it — otherwise it only ever grows and every bump jumps further.
    test "a claim at or below the released number is dropped", %{dir: dir} do
      write_mix(dir, "7.304.0")
      fake_gh(dir, %{})
      file_claim(dir, "7.303.9", "long-merged")

      result = run(dir, "patch", claims: claims_dir(dir))

      assert result.version == "7.304.1"
      refute File.exists?(Path.join(claims_dir(dir), "7.303.9"))
    end

    test "`list` reports the register and changes nothing", %{dir: dir} do
      write_mix(dir, "7.304.0")
      fake_gh(dir, %{})
      file_claim(dir, "7.305.0", "somebody-else")

      result = run(dir, "list", claims: claims_dir(dir))

      assert result.status == 0
      assert result.version == "7.304.0"
      assert result.output =~ "7.305.0"
      assert result.output =~ "somebody-else"
    end
  end
end
