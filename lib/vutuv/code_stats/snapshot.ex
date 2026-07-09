defmodule Vutuv.CodeStats.Snapshot do
  @moduledoc """
  Builds the provider-neutral snapshot map (`Vutuv.CodeStats`) from a client's
  normalized profile + repository list, so the three forge clients share one
  aggregation and the card renders one shape.

  String keys on purpose: the map round-trips through the jsonb column, so
  reading code sees string keys either way. Every profile field is optional
  (`nil` when a forge doesn't expose it — GitLab has no public follower count
  or repo language) and the card simply omits the line.

  It also carries the small request helpers the three forge clients share
  (handle validation, JSON decoding, the `x-total*` count header), so a client
  is only its provider-specific paths, regexes and header names.
  """

  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  @top_repos 3
  @top_languages 3
  @recent_days 365
  @description_max 160

  @doc """
  The snapshot. `profile` carries `:followers`, `:public_repos` and
  `:member_since` (a `Date` or nil); `repos` is a list of
  `%{name:, url:, description:, language:, stars:, fork?:, pushed_at:}` maps
  (`pushed_at` a `DateTime` or nil). Forks count for "last active" but are
  excluded from stars, languages and top repositories — starring happens on
  the upstream, not the fork.
  """
  def build(profile, repos) do
    own = Enum.reject(repos, & &1.fork?)

    %{
      "followers" => profile[:followers],
      "public_repos" => profile[:public_repos] || length(repos),
      "member_since" => iso_date(profile[:member_since]),
      "total_stars" => own |> Enum.map(& &1.stars) |> Enum.sum(),
      "languages" => languages(own),
      "last_active_at" => last_active(repos),
      "recent_repos" => recent_count(own),
      "top_repos" => top_repos(own)
    }
  end

  # ── Parse helpers shared by the three forge clients (untrusted JSON) ──

  @doc "A non-negative integer from remote JSON, else nil."
  def int(value) when is_integer(value) and value >= 0, do: value
  def int(_), do: nil

  @doc "The Date of an ISO-8601 timestamp from remote JSON, else nil."
  def date(value) do
    case datetime(value) do
      %DateTime{} = dt -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  @doc "A DateTime from a remote ISO-8601 string, else nil."
  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  def datetime(_), do: nil

  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)
  defp iso_date(_), do: nil

  # ── Request helpers shared by the three forge clients ──

  @doc """
  Validates a forge handle against the provider's `regex` before it is embedded
  in an API path/query: `{:ok, handle}`, or `{:error, :gone}` for a non-binary
  or a handle that does not match (a malformed handle is not coming back).
  """
  def validate_handle(handle, regex) when is_binary(handle) do
    if Regex.match?(regex, handle), do: {:ok, handle}, else: {:error, :gone}
  end

  def validate_handle(_handle, _regex), do: {:error, :gone}

  @doc "Decodes a JSON body, folding any failure (incl. oversize) to `{:error, :transient}`."
  def decode_or_transient(body) do
    case Http.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :transient}
    end
  end

  @doc """
  The non-negative integer in a paging total header (`header`, e.g. `\"x-total\"`
  or `\"x-total-count\"`) of `resp`, or nil when absent or unparseable.
  """
  def total_count(resp, header) do
    case Req.Response.get_header(resp, header) do
      [value | _] ->
        case Integer.parse(value) do
          {total, ""} when total >= 0 -> total
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The languages the member's own repositories use most, by repo count.
  defp languages(repos) do
    repos
    |> Enum.map(& &1.language)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_language, count} -> -count end)
    |> Enum.take(@top_languages)
    |> Enum.map(fn {language, _count} -> language end)
  end

  # The most recent push across ALL repos (a member active only in their
  # fork of an upstream project is still active).
  defp last_active(repos) do
    repos
    |> Enum.map(& &1.pushed_at)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] -> nil
      dates -> dates |> Enum.max(DateTime) |> DateTime.to_iso8601()
    end
  end

  defp recent_count(repos) do
    cutoff = DateTime.add(DateTime.utc_now(), -@recent_days, :day)

    Enum.count(repos, fn repo ->
      match?(%DateTime{}, repo.pushed_at) and DateTime.compare(repo.pushed_at, cutoff) == :gt
    end)
  end

  defp top_repos(repos) do
    repos
    |> Enum.sort_by(&{-&1.stars, invert_datetime(&1.pushed_at)})
    |> Enum.take(@top_repos)
    |> Enum.map(fn repo ->
      %{
        "name" => repo.name,
        "url" => repo.url,
        "description" => truncate(repo.description),
        # Forgejo sends "" for a language-less repo; store nil so the
        # renderers' is-binary/non-empty guards drop the field cleanly.
        "language" => presence(repo.language),
        "stars" => repo.stars
      }
    end)
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  # Sort helper: newest pushed_at first among equal star counts (nil last).
  defp invert_datetime(%DateTime{} = dt), do: -DateTime.to_unix(dt)
  defp invert_datetime(_), do: 0

  defp truncate(description) when is_binary(description),
    do: Post.truncate(description, @description_max)

  defp truncate(_), do: nil
end
