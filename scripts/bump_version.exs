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

level = List.first(System.argv()) || "patch"
path = "mix.exs"
source = File.read!(path)

case parse.(source) do
  nil ->
    IO.puts(:stderr, "could not find a `version: \"X.Y.Z\"` line in #{path}")
    System.halt(1)

  local ->
    claims = claimed_versions.()

    # Report every claim that constrains this bump, including one equal to the
    # local number: that is the dangerous case, the one that produces two
    # changes wearing the same version with no conflict to warn anybody.
    for {number, {major, minor, patch} = version} <- claims, version >= local do
      IO.puts(:stderr, "bump_version: PR ##{number} already claims #{major}.#{minor}.#{patch}")
    end

    # Start from the highest number anybody has taken, so the bump lands past
    # every claim instead of beside one.
    {major, minor, patch} = Enum.max([local | Enum.map(claims, &elem(&1, 1))])

    {new_major, new_minor, new_patch} =
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

    new_version = "#{new_major}.#{new_minor}.#{new_patch}"
    new_source = String.replace(source, re, ~s(version: "#{new_version}"), global: false)
    File.write!(path, new_source)
    IO.puts(new_version)
end
