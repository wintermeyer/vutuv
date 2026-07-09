defmodule Vutuv.CodeStats.GitHub do
  @moduledoc """
  The GitHub client of the code-forge statistics (`Vutuv.CodeStats`): two
  REST requests per snapshot — the public user (followers, repo count,
  member since) and the repository list (up to 100 repos, newest pushes
  first, which covers stars/languages/activity for all but extreme accounts).

  Unauthenticated GitHub allows 60 requests/hour per IP; the optional
  `GITHUB_API_TOKEN` env var (`:github_api_token`, read in
  `config/runtime.exs`) raises that to 5,000/hour and is sent as a Bearer
  header when present — nothing else changes, so it can be added to a
  running installation at any time (see docs/ADMINS.md). A rate-limited
  answer (403/429) is a transient failure that walks the backoff ladder.
  """

  require Logger

  alias Vutuv.CodeStats.Snapshot
  alias Vutuv.SocialFeed.Http

  # The public REST API — a fixed host, never member input.
  @api "https://api.github.com"

  # A GitHub login: alphanumeric with inner hyphens, at most 39 chars. Only
  # this shape may be embedded in the API paths.
  @handle_format ~r/^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :github_req_options

  @doc """
  The blocking fetch (run inside the fetcher's task, and directly by tests):
  `{:ok, stats_map}` or a classified `{:error, :gone | :transient}`.
  """
  def fetch_stats(handle) do
    with {:ok, handle} <- Snapshot.validate_handle(handle, @handle_format),
         {:ok, user} when is_map(user) <- get_json("/users/#{handle}"),
         {:ok, repos} when is_list(repos) <-
           get_json("/users/#{handle}/repos?per_page=100&sort=pushed") do
      profile = %{
        followers: Snapshot.int(user["followers"]),
        public_repos: Snapshot.int(user["public_repos"]),
        member_since: Snapshot.date(user["created_at"])
      }

      {:ok, Snapshot.build(profile, normalize_repos(repos))}
    else
      {:error, reason} -> {:error, reason}
      _unexpected_shape -> {:error, :transient}
    end
  rescue
    error ->
      Logger.warning("github stats fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp get_json(path) do
    case Http.get(@api <> path, @req_options, headers: headers()) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Snapshot.decode_or_transient(body)

      # An unknown user is not coming back on its own; everything else
      # (rate limit 403/429, 5xx, network) retries via the backoff ladder.
      {:ok, %Req.Response{status: 404}} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  defp headers do
    base = [
      {"user-agent", Http.user_agent()},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case Application.get_env(:vutuv, :github_api_token) do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | base]

      _ ->
        base
    end
  end

  defp normalize_repos(repos) do
    for repo when is_map(repo) <- repos do
      %{
        name: repo["name"],
        url: repo["html_url"],
        description: repo["description"],
        language: repo["language"],
        stars: Snapshot.int(repo["stargazers_count"]) || 0,
        fork?: repo["fork"] == true,
        pushed_at: Snapshot.datetime(repo["pushed_at"])
      }
    end
  end
end
