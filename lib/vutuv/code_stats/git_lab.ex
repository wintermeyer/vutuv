defmodule Vutuv.CodeStats.GitLab do
  @moduledoc """
  The GitLab client of the code-forge statistics (`Vutuv.CodeStats`): two
  requests against gitlab.com — the username lookup (the API is id-keyed) and
  the user's project list, newest activity first. GitLab's public API exposes
  less than the other forges: no follower count and no per-project language,
  so those snapshot fields stay nil/empty and the card omits them. The full
  project count comes from the `x-total` header (the list pages at 100).
  """

  require Logger

  alias Vutuv.CodeStats.Snapshot
  alias Vutuv.SocialFeed.Http

  # The public REST API of gitlab.com — a fixed host, never member input.
  @api "https://gitlab.com/api/v4"

  # A GitLab username: alphanumeric with dots, dashes and underscores. Only
  # this shape may be embedded in the API query.
  @handle_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :gitlab_req_options

  @doc """
  The blocking fetch (run inside the fetcher's task, and directly by tests):
  `{:ok, stats_map}` or a classified `{:error, :gone | :transient}`.
  """
  def fetch_stats(handle) do
    with {:ok, handle} <- validate_handle(handle),
         {:ok, user} when is_map(user) <- lookup_user(handle),
         {:ok, projects, total} when is_list(projects) <- fetch_projects(user["id"]) do
      profile = %{
        # gitlab.com exposes no public follower count.
        followers: nil,
        public_repos: total,
        member_since: Snapshot.date(user["created_at"])
      }

      {:ok, Snapshot.build(profile, normalize_projects(projects))}
    else
      {:error, reason} -> {:error, reason}
      _unexpected_shape -> {:error, :transient}
    end
  rescue
    error ->
      Logger.warning("gitlab stats fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp validate_handle(handle) when is_binary(handle) do
    if Regex.match?(@handle_format, handle), do: {:ok, handle}, else: {:error, :gone}
  end

  defp validate_handle(_handle), do: {:error, :gone}

  # The users endpoint answers 200 with an empty list for an unknown
  # username — the account is not coming back on its own, exactly like a
  # GitHub 404.
  defp lookup_user(handle) do
    case Http.get(@api <> "/users?username=#{handle}", @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode(body) do
          {:ok, [user | _]} when is_map(user) -> {:ok, user}
          {:ok, []} -> {:error, :gone}
          _ -> {:error, :transient}
        end

      _other ->
        {:error, :transient}
    end
  end

  defp fetch_projects(id) when is_integer(id) do
    url = @api <> "/users/#{id}/projects?per_page=100&order_by=last_activity_at"

    case Http.get(url, @req_options) do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        with {:ok, projects} when is_list(projects) <- decode(body) do
          {:ok, projects, total_count(resp) || length(projects)}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  defp fetch_projects(_id), do: {:error, :transient}

  defp total_count(resp) do
    case Req.Response.get_header(resp, "x-total") do
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

  defp normalize_projects(projects) do
    for project when is_map(project) <- projects do
      %{
        name: project["path"] || project["name"],
        url: project["web_url"],
        description: project["description"],
        # The project list carries no language; the card omits the line.
        language: nil,
        stars: Snapshot.int(project["star_count"]) || 0,
        fork?: false,
        pushed_at: Snapshot.datetime(project["last_activity_at"])
      }
    end
  end
end
