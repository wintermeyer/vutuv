# Bumps the `version:` in mix.exs and prints the new version to stdout.
#
# Usage:  elixir scripts/bump_version.exs [patch|minor|major]
#   patch (default)  fixes, refactors, docs, config, internal changes
#   minor            a new backward-compatible user-facing feature
#   major            a breaking change (only when agreed with Stefan)
#
# Deterministic on purpose: the deploy flow calls this instead of having an
# agent read mix.exs, do the arithmetic, and hand-edit the file — that spent
# reasoning tokens on a mechanical bump and could drift. Exits non-zero (so a
# `set -o pipefail` caller notices) if the version line can't be found or the
# level is unknown.
#
# **It bumps past the numbers other open pull requests have already claimed**,
# not merely past the one in the local file. Bumping from `origin/main` alone is
# what kept producing collisions: an unmerged PR holds the next number for
# hours, so main still looks free, both sides write the same version, and
# because they agree there is no merge conflict and no warning — one number
# silently ends up naming two unrelated changes (four times on 2026-08-17
# alone). Every open PR carries its claim in its own mix.exs, so the claims are
# readable: this asks `gh` for them and starts from the highest.
#
# Skipping a number costs nothing if that PR is later closed, so the answer is
# allowed to be generous. It is a **backstop, not a guarantee**: a PR opened in
# the seconds after this runs is still invisible, and when `gh` cannot answer at
# all (missing, unauthenticated, offline) the script says so on stderr and bumps
# from the local file exactly as before — refusing to bump would block a deploy
# over a network hiccup, and the fallback is only as wrong as the old behaviour.
# So the rule it supports stands: re-check `origin/main` immediately before
# merging.
#
# Runs as a plain `elixir` script, so it may use no dependencies: `gh --jq`
# renders the PR list as tab-separated lines rather than JSON somebody here
# would have to parse.
#
# **Second register, for the numbers GitHub cannot see yet.** The open-PR check
# above only sees a claim once the PR exists, and the stretch between bumping
# and opening one (precommit, commit, push) is minutes long — the very window
# several sessions work in at once. So a bump also **files its claim locally**,
# in a directory under the shared `.git`: one file per version, named after it,
# holding the branch, the note and the time. `.git` is the right home because
# every worktree of this checkout shares it (`git rev-parse --git-common-dir`)
# and nothing under it is ever committed or pushed — no `.gitignore` entry to
# forget, no `git add -A` that can sweep it into a commit.
#
# The claim is taken by creating that file **exclusively**, so it is a real
# lock rather than a note: two sessions racing for the same number cannot both
# win, the loser simply takes the next one. Claims expire on their own — one
# whose number `main` has already reached is spent, and anything older than a
# day belonged to a session that is long gone.
#
#   elixir scripts/bump_version.exs list            # who holds what
#   elixir scripts/bump_version.exs patch "Kurznotiz, woran ich arbeite"

re = ~r/version:\s*"(\d+)\.(\d+)\.(\d+)"/

parse = fn source ->
  case Regex.run(re, source) do
    [_full, major, minor, patch] ->
      {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

    _ ->
      nil
  end
end

# `{output, 0}` or `{:error, reason}`. Wrapped because a missing executable
# raises rather than returning a status.
run = fn command, args ->
  try do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _status} -> {:error, String.trim(out)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end

# The branch this bump belongs to: its own PR must not push the number along
# again every time the script is re-run after a rebase.
own_branch =
  case run.("git", ["rev-parse", "--abbrev-ref", "HEAD"]) do
    {:ok, out} -> String.trim(out)
    {:error, _} -> nil
  end

# The version one PR's branch claims, read from that branch's own mix.exs (one
# small request per PR — the file itself, never the whole diff).
claim_of = fn sha ->
  with {:ok, body} <-
         run.("gh", ["api", "repos/{owner}/{repo}/contents/mix.exs?ref=#{sha}", "--jq", ".content"]),
       {:ok, decoded} <- Base.decode64(String.replace(body, ["\n", " "], "")) do
    parse.(decoded)
  else
    _unreadable -> nil
  end
end

claimed_versions = fn ->
  case run.("gh", [
         "pr",
         "list",
         "--state",
         "open",
         "--json",
         "number,headRefName,headRefOid",
         "--jq",
         ".[] | [.number, .headRefName, .headRefOid] | @tsv"
       ]) do
    {:ok, out} ->
      out
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t") do
          [number, branch, sha] when branch != own_branch ->
            case claim_of.(sha) do
              nil -> []
              version -> [{number, version}]
            end

          _ ->
            []
        end
      end)

    {:error, reason} ->
      IO.puts(:stderr, "bump_version: could not read the open PRs (#{reason}); using mix.exs only")
      []
  end
end

# The shared register's directory. Under the **common** git dir, so all
# worktrees of this checkout see the same one; overridable for the tests, which
# run the script outside any repository.
claims_dir =
  case System.get_env("VUTUV_VERSION_CLAIMS_DIR") do
    nil ->
      case run.("git", ["rev-parse", "--git-common-dir"]) do
        {:ok, out} -> out |> String.trim() |> Path.expand() |> Path.join("vutuv-version-claims")
        {:error, _not_a_repo} -> nil
      end

    dir ->
      dir
  end

one_day = 24 * 60 * 60
version_string = fn {major, minor, patch} -> "#{major}.#{minor}.#{patch}" end

# A file name is the claim's version; anything else in the directory is ignored.
claim_version = fn name -> parse.(~s(version: "#{name}")) end

# Everything the register holds, oldest number first. The file is three
# `key: value` lines so a person who opens it reads a sentence, not a record.
read_claims = fn dir ->
  for name <- File.ls!(dir), version = claim_version.(name) do
    fields =
      Path.join(dir, name)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, ": ", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    {version, Map.get(fields, "branch", "?"), Map.get(fields, "note", ""),
     Map.get(fields, "at", "?")}
  end
  |> Enum.sort()
end

# A claim is spent once the version in mix.exs has reached its number, and one
# older than a day belonged to a session that is not coming back. Its own
# branch's claims go too, or re-running after a rebase would push the number
# along again. Deleted rather than skipped, so the register stays readable
# instead of growing a tail of ghosts.
prune_claims = fn dir, local, own_branch ->
  now = System.os_time(:second)

  for name <- File.ls!(dir), version = claim_version.(name) do
    file = Path.join(dir, name)

    mine_or_stale? =
      version <= local or
        Enum.any?(read_claims.(dir), fn {v, branch, _note, _at} ->
          v == version and branch == own_branch and own_branch != nil
        end) or
        case File.stat(file, time: :posix) do
          {:ok, %{mtime: mtime}} -> now - mtime > one_day
          _ -> true
        end

    if mine_or_stale?, do: File.rm(file)
  end
end

# Files the claim by creating its file exclusively: `{:ok, _}` means this
# session got the number, `{:error, :eexist}` that somebody else did between
# the read above and this write. That race is the whole reason the register is
# one file per version rather than one shared list.
file_claim = fn dir, version, own_branch, note ->
  body = """
  branch: #{own_branch || "?"}
  note: #{note || "(keine Notiz)"}
  at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
  """

  # `:utf8` is not optional: without it Erlang writes a note's umlauts as raw
  # latin-1 bytes, and reading the file back then raises on the first "ü".
  case File.open(Path.join(dir, version_string.(version)), [:write, :exclusive, :utf8]) do
    {:ok, io} ->
      IO.write(io, body)
      File.close(io)
      :ok

    {:error, _taken} ->
      :taken
  end
end

args = System.argv()
level = Enum.at(args, 0) || "patch"
note = Enum.at(args, 1)
path = "mix.exs"

# `list` answers the question the register exists for and changes nothing.
if level == "list" do
  case claims_dir do
    nil ->
      IO.puts(:stderr, "no shared git dir found, so there is no claims register here")

    dir ->
      File.mkdir_p!(dir)

      case read_claims.(dir) do
        [] ->
          IO.puts("no version claims filed")

        claims ->
          for {version, branch, note, at} <- claims do
            IO.puts("#{version_string.(version)}  #{branch}  #{at}  #{note}")
          end
      end
  end

  System.halt(0)
end

source = File.read!(path)

case parse.(source) do
  nil ->
    IO.puts(:stderr, "could not find a `version: \"X.Y.Z\"` line in #{path}")
    System.halt(1)

  local ->
    pr_claims = claimed_versions.()

    # Report every claim that constrains this bump, including one equal to the
    # local number: that is the dangerous case, the one that produces two
    # changes wearing the same version with no conflict to warn anybody.
    for {number, version} <- pr_claims, version >= local do
      IO.puts(:stderr, "bump_version: PR ##{number} already claims #{version_string.(version)}")
    end

    local_claims =
      case claims_dir do
        nil ->
          []

        dir ->
          File.mkdir_p!(dir)
          prune_claims.(dir, local, own_branch)

          for {version, branch, note, _at} <- read_claims.(dir) do
            IO.puts(
              :stderr,
              "bump_version: #{branch} claims #{version_string.(version)} (#{note})"
            )

            version
          end
      end

    # Start from the highest number anybody has taken, so the bump lands past
    # every claim instead of beside one.
    base = Enum.max([local | Enum.map(pr_claims, &elem(&1, 1)) ++ local_claims])

    next = fn {major, minor, patch} ->
      case level do
        "patch" ->
          {major, minor, patch + 1}

        "minor" ->
          {major, minor + 1, 0}

        "major" ->
          {major + 1, 0, 0}

        other ->
          IO.puts(:stderr, "unknown level #{inspect(other)} (use patch|minor|major)")
          System.halt(1)
      end
    end

    # Take the number by creating its file; if another session got there in the
    # meantime, step up and try again. Without a register the first candidate
    # simply stands.
    take = fn take, candidate ->
      case claims_dir do
        nil ->
          candidate

        dir ->
          case file_claim.(dir, candidate, own_branch, note) do
            :ok -> candidate
            :taken -> take.(take, next.(candidate))
          end
      end
    end

    version = take.(take, next.(base))
    new_version = version_string.(version)
    new_source = String.replace(source, re, ~s(version: "#{new_version}"), global: false)
    File.write!(path, new_source)
    IO.puts(new_version)
end
