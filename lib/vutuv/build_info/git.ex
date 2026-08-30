defmodule Vutuv.BuildInfo.Git do
  @moduledoc """
  Asks git which commit `HEAD` is, for `Vutuv.BuildInfo` to freeze in at
  compile time. Its own module because `BuildInfo` needs the answer while it
  is still being defined, and a module cannot call its own functions from its
  body.
  """

  @doc """
  The abbreviated sha and the committer instant (UTC) of `HEAD`; nil when git
  is missing, or the working directory is not a repository.
  """
  @spec stamp() :: {String.t(), DateTime.t()} | nil
  def stamp do
    case git(["log", "-1", "--format=%h %cI"]) do
      {output, 0} -> parse(output)
      _ -> nil
    end
  end

  @doc """
  The file git appends to whenever `HEAD` moves in this checkout (a commit, a
  checkout, a rebase): the reflog, resolved for a worktree as well as for a
  plain clone. `Vutuv.BuildInfo` declares it as an external resource, which is
  what brings a development build back to the current commit without forking
  git on every compile. Nil without git.
  """
  @spec head_log() :: String.t() | nil
  def head_log do
    case git(["rev-parse", "--git-path", "logs/HEAD"]) do
      {path, 0} -> Path.expand(String.trim(path))
      _ -> nil
    end
  end

  @doc """
  Parses one line of `git log -1 --format="%h %cI"`; nil for anything else
  git may have said (an error message, or nothing at all).
  """
  @spec parse(String.t()) :: {String.t(), DateTime.t()} | nil
  def parse(output) do
    with [sha, iso] <- String.split(String.trim(output), " ", parts: 2),
         true <- sha =~ ~r/^[0-9a-f]{7,40}$/,
         {:ok, at, _offset} <- DateTime.from_iso8601(iso) do
      {sha, at}
    else
      _ -> nil
    end
  end

  defp git(args) do
    case System.find_executable("git") do
      nil -> :no_git
      git -> System.cmd(git, args, stderr_to_stdout: true)
    end
  end
end
