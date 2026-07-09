defmodule Vutuv.CodeStats.Codeberg do
  @moduledoc """
  The Codeberg client of the code-forge statistics (`Vutuv.CodeStats`): two
  requests against the Forgejo API — the public user (followers, member
  since) and the repository list. Forgejo pages repositories at 50, so the
  total repo count comes from the `x-total-count` header while stars,
  languages and activity aggregate over the newest-updated page (plenty for
  the card's glanceable facts).
  """

  require Logger

  alias Vutuv.CodeStats.Snapshot
  alias Vutuv.SocialFeed.Http

  # The public Forgejo API — a fixed host, never member input.
  @api "https://codeberg.org/api/v1"

  # A Forgejo username: alphanumeric with dots, dashes and underscores. Only
  # this shape may be embedded in the API paths.
  @handle_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :codeberg_req_options

  @doc """
  The blocking fetch (run inside the fetcher's task, and directly by tests):
  `{:ok, stats_map}` or a classified `{:error, :gone | :transient}`.
  """
  def fetch_stats(handle) do
    with {:ok, handle} <- validate_handle(handle),
         {:ok, user} when is_map(user) <- fetch_user(handle),
         {:ok, repos, total} when is_list(repos) <- fetch_repos(handle) do
      profile = %{
        followers: Snapshot.int(user["followers_count"]),
        public_repos: total,
        member_since: Snapshot.date(user["created"])
      }

      {:ok, Snapshot.build(profile, normalize_repos(repos))}
    else
      {:error, reason} -> {:error, reason}
      _unexpected_shape -> {:error, :transient}
    end
  rescue
    error ->
      Logger.warning("codeberg stats fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp validate_handle(handle) when is_binary(handle) do
    if Regex.match?(@handle_format, handle), do: {:ok, handle}, else: {:error, :gone}
  end

  defp validate_handle(_handle), do: {:error, :gone}

  defp fetch_user(handle) do
    case Http.get(@api <> "/users/#{handle}", @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: 404}} -> {:error, :gone}
      _other -> {:error, :transient}
    end
  end

  # The repository listing carries the x-total-count header for the full
  # count beyond this page.
  defp fetch_repos(handle) do
    case Http.get(@api <> "/users/#{handle}/repos?limit=50", @req_options) do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        with {:ok, repos} when is_list(repos) <- decode(body) do
          {:ok, repos, total_count(resp) || length(repos)}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  defp total_count(resp) do
    case Req.Response.get_header(resp, "x-total-count") do
      [value | _] ->
        case Integer.parse(value) do
          {total, ""} when total >= 0 -> total
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp decode(body) do
    case Http.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :transient}
    end
  end

  defp normalize_repos(repos) do
    for repo when is_map(repo) <- repos do
      %{
        name: repo["name"],
        url: repo["html_url"],
        description: repo["description"],
        language: repo["language"],
        stars: Snapshot.int(repo["stars_count"]) || 0,
        fork?: repo["fork"] == true,
        pushed_at: Snapshot.datetime(repo["updated_at"])
      }
    end
  end
end
