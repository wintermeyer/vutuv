defmodule Vutuv.BuildInfo do
  @moduledoc """
  Which commit this release was built from, and when.

  There is no version number to report: the application version in `mix.exs`
  is the date of the commit being built, so what identifies a release is the
  commit itself. Both values are frozen into the BEAM at compile time.
  Production deploys are blue/green from a *fresh* CI checkout, so every deploy
  recompiles from scratch and reads the merge commit that triggered it. A
  development checkout recompiles this module when `HEAD` moves: git's reflog
  is declared as an external resource, so the compiler's file check catches a
  commit or a checkout, and nothing forks git on the compile that runs before
  every dev request.

  The commit instant is the moment the pull request merged, a few minutes
  before traffic switches - close enough for "when did this go live". Without
  git (a checkout that is not a repository) the footer dates the site by the
  build instant and names no commit. Those two answers are decided here at
  compile time, as two definitions rather than one branch: the compiler knows
  which one it is building and would flag a runtime check on it as always
  true.
  """

  alias Vutuv.BerlinTime
  alias Vutuv.BuildInfo.Git
  alias Vutuv.SourceRepo

  # A plain variable, not an attribute: `||` reads its right-hand side only
  # when there is no commit, and an attribute read that never runs is "set but
  # never used" to the compiler.
  built_at = DateTime.truncate(DateTime.utc_now(), :second)
  @git_stamp Git.stamp()
  @commit_sha if(@git_stamp, do: elem(@git_stamp, 0))
  @committed_at if(@git_stamp, do: elem(@git_stamp, 1))
  @stamp @committed_at || built_at

  for path <- List.wrap(Git.head_log()) do
    Module.put_attribute(__MODULE__, :external_resource, path)
  end

  @doc """
  The application version: the commit date as `2026.8.29` (`mix.exs`), or
  `0.0.0` for a build without git. NodeInfo, the Mastodon API's instance
  version and the outbound user agent are its readers; nothing compares it.
  """
  @spec version() :: String.t()
  def version, do: to_string(Application.spec(:vutuv, :vsn))

  @doc "The abbreviated sha of the commit this release was built from, nil without git."
  @spec commit_sha() :: String.t() | nil
  def commit_sha, do: @commit_sha

  @doc "The UTC instant of that commit, nil without git."
  @spec committed_at() :: DateTime.t() | nil
  def committed_at, do: @committed_at

  @doc "The commit's page in the configured source repository, nil without git."
  @spec commit_url() :: String.t() | nil
  case @git_stamp do
    {sha, _at} -> def commit_url, do: SourceRepo.commit_url(unquote(sha))
    nil -> def commit_url, do: nil
  end

  @doc "The instant the footer dates the site by: the commit, else the build."
  @spec stamp() :: DateTime.t()
  def stamp, do: @stamp

  @doc """
  An instant as a Europe/Berlin wall clock date, `DD.MM.YYYY`, defaulting to
  `stamp/0`. The footer pairs it with `berlin_time/1` inside a gettext message
  so each locale supplies its own connective ("um … Uhr" / "at …") rather than
  baking German into the value.
  """
  @spec berlin_date(DateTime.t()) :: String.t()
  def berlin_date(utc \\ stamp()) do
    utc
    |> BerlinTime.naive()
    |> Calendar.strftime("%d.%m.%Y")
  end

  @doc "An instant as a Europe/Berlin wall clock time, `HH:MM`. See `berlin_date/1`."
  @spec berlin_time(DateTime.t()) :: String.t()
  def berlin_time(utc \\ stamp()) do
    utc
    |> BerlinTime.naive()
    |> Calendar.strftime("%H:%M")
  end
end
