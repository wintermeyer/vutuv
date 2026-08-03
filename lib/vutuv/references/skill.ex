defmodule Vutuv.References.Skill do
  @moduledoc """
  The analysis prompt: where it comes from, how it is checked, and which
  version produced a given result.

  The Arbeitszeugnis check runs on an open skill — a ~131 KB Markdown document
  maintained at

      https://github.com/Klotzkette/arbeitszeugnispruefer-skill

  under MIT/Apache-2.0, and **a copy of it ships in this repository** at
  `priv/reference_skill/SKILL.md`. That copy is the source of record: the
  prompt that was reviewed is the prompt that runs, changing it is a reviewable
  commit, and answering a member never depends on GitHub being reachable.

  `Vutuv.References.SkillRefresher` can re-fetch it daily, but that is **off by
  default** (`:fetch_reference_skill`). For a prompt that produces legal
  readings, an unreviewed overnight change upstream is worse than waiting for a
  deploy. An operator who wants upstream corrections sooner can switch it on.

  ## Adopting a fetched body is a decision, not a copy

  Whatever arrives is checked before it can become the live prompt
  (`valid_body?/1`): it must declare the skill's own frontmatter name, carry a
  `Version:` line, and be at least `@min_body_bytes` long. Anything else — a
  404 page, a truncated response, a repository that moved, a redirect to a
  login form — leaves the previous body in force and is logged.

  That is the fail-closed half of the rule. The open half would be worse than
  it looks: a short or empty prompt does not make the model refuse, it makes
  the model answer from its own training with no legal anchors at all, and the
  answer still arrives formatted, confident and wrong.

  Every check records `skill_version` and `skill_sha256`, so two results months
  apart can be explained rather than merely compared.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vutuv.References.SkillVersion
  alias Vutuv.Repo

  @source_url "https://raw.githubusercontent.com/Klotzkette/arbeitszeugnispruefer-skill/refs/heads/main/skill/SKILL.md"

  @project_url "https://github.com/Klotzkette/arbeitszeugnispruefer-skill"

  # The frontmatter name the real skill declares. A body without it is not the
  # thing we asked for, whatever else it may be.
  @required_name "arbeitszeugnis-pruefer"

  # Measured: the real document is ~131 KB / ~35_200 tokens. Half of that is
  # far below anything legitimate and far above any error page.
  @min_body_bytes 50_000

  @doc "Where the skill is fetched from."
  def source_url, do: Application.get_env(:vutuv, :reference_skill_url, @source_url)

  @doc "The project to credit in every rendered result (MIT/Apache-2.0)."
  def project_url, do: @project_url

  @doc """
  Whether this installation fetches the skill from the internet at all.

  Defaults to **false**, matching the config: an absent key must mean "run the
  reviewed copy in the repository", never "reach out to GitHub". The safe
  reading of a missing switch is the one that changes nothing.
  """
  def fetch_enabled?, do: Application.get_env(:vutuv, :fetch_reference_skill, false)

  @doc """
  The prompt in force, as a `%Vutuv.References.SkillVersion{}`.

  The newest stored row, or — on an installation that has never fetched — the
  vendored copy, which is written to the table on first use so a check can
  always point at a real row.
  """
  def current do
    case newest() do
      nil -> adopt_vendored()
      version -> version
    end
  end

  defp newest do
    SkillVersion
    |> order_by([v], desc: v.fetched_at, desc: v.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Fetches the skill and stores it when it is both valid and new.

  Returns `{:ok, version}` when a body is in force afterwards (fetched or
  already known), `{:error, reason}` when nothing could be established. Never
  raises: it runs on a timer, and a GitHub outage is not an incident here.
  """
  def refresh do
    if fetch_enabled?(), do: fetch_and_store(), else: {:ok, current()}
  end

  defp fetch_and_store do
    case fetch() do
      {:ok, body} -> store(body, "remote")
      {:error, reason} -> fall_back(reason)
    end
  end

  # A failed fetch is not a failure of the feature: the previous body (or the
  # vendored one) stays in force and checks keep running on it.
  defp fall_back(reason) do
    Logger.warning("reference skill fetch failed (#{inspect(reason)}); keeping current body")

    case current() do
      nil -> {:error, reason}
      version -> {:ok, version}
    end
  end

  defp fetch do
    [url: source_url(), receive_timeout: 30_000, connect_options: [timeout: 10_000], retry: false]
    |> Keyword.merge(Application.get_env(:vutuv, :reference_skill_req_options, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if valid_body?(body), do: {:ok, body}, else: {:error, :not_the_skill}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether a fetched body really is the skill.

  Three cheap checks that together exclude every failure this has: an error
  page, a truncated download, a moved repository serving something else.
  """
  def valid_body?(body) when is_binary(body) do
    byte_size(body) >= min_body_bytes() and
      String.contains?(body, "name: #{@required_name}") and
      version_of(body) != nil
  end

  def valid_body?(_other), do: false

  @doc "The `Version:` the body declares, or nil."
  def version_of(body) when is_binary(body) do
    case Regex.run(~r/^Version:\s*(\S+)/m, body) do
      [_all, version] -> version
      _none -> nil
    end
  end

  def version_of(_other), do: nil

  @doc "The minimum plausible size of a real skill body, in bytes."
  def min_body_bytes, do: Application.get_env(:vutuv, :reference_skill_min_bytes, @min_body_bytes)

  @doc "SHA-256 of a body, lowercase hex — the identity of a prompt."
  def digest(body) when is_binary(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  @doc """
  Stores `body` as the version in force.

  Idempotent by digest: the daily fetch usually returns exactly what is
  already stored, and that must refresh `fetched_at` rather than pile up rows.
  """
  def store(body, source) when is_binary(body) and source in ~w(remote vendored) do
    if valid_body?(body) do
      sha = digest(body)
      now = DateTime.utc_now(:second)

      %SkillVersion{}
      |> SkillVersion.changeset(%{
        version: version_of(body),
        sha256: sha,
        body: body,
        source: source,
        fetched_at: now
      })
      |> Repo.insert(
        on_conflict: [set: [fetched_at: now, source: source]],
        conflict_target: :sha256,
        returning: true
      )
    else
      {:error, :not_the_skill}
    end
  end

  @doc """
  The vendored copy shipped in `priv/`, or nil when it is missing.

  Reading it is deliberately not cached: it is touched once at first use and
  then never again, because a stored row exists from that point on.
  """
  def vendored_body do
    path = Application.app_dir(:vutuv, "priv/reference_skill/SKILL.md")

    case File.read(path) do
      {:ok, body} -> body
      {:error, _reason} -> nil
    end
  end

  defp adopt_vendored do
    with body when is_binary(body) <- vendored_body(),
         {:ok, version} <- store(body, "vendored") do
      version
    else
      _unavailable ->
        Logger.error("no reference skill available: neither stored nor vendored")
        nil
    end
  end
end
