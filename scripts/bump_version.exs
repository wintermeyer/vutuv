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

level = List.first(System.argv()) || "patch"
path = "mix.exs"
source = File.read!(path)

re = ~r/version:\s*"(\d+)\.(\d+)\.(\d+)"/

case Regex.run(re, source) do
  [_full, major, minor, patch] ->
    {major, minor, patch} = {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

    {new_major, new_minor, new_patch} =
      case level do
        "patch" -> {major, minor, patch + 1}
        "minor" -> {major, minor + 1, 0}
        "major" -> {major + 1, 0, 0}
        other ->
          IO.puts(:stderr, "unknown level #{inspect(other)} (use patch|minor|major)")
          System.halt(1)
      end

    new_version = "#{new_major}.#{new_minor}.#{new_patch}"
    new_source = String.replace(source, re, ~s(version: "#{new_version}"), global: false)
    File.write!(path, new_source)
    IO.puts(new_version)

  _ ->
    IO.puts(:stderr, "could not find a `version: \"X.Y.Z\"` line in #{path}")
    System.halt(1)
end
