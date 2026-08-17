defmodule Vutuv.CodeStats.Forgejo do
  @moduledoc """
  The Gitea / Forgejo client of the code-forge statistics (`Vutuv.CodeStats`):
  two requests against the Gitea-compatible API v1 — the public user (followers,
  member since, the profile fields the verification reads) and the repository
  list. Both forges page repositories at 50, so the total repo count comes from
  the `x-total-count` header while stars, languages and activity aggregate over
  the newest-updated page (plenty for the card's glanceable facts).

  It serves two kinds of caller, which is why the API base is an argument rather
  than a module attribute. `Vutuv.CodeStats.Codeberg` points it at one fixed,
  trusted host — codeberg.org runs Forgejo, so that client is this one with the
  host filled in. A **self-hosted** account (provider "Gitea" / "Forgejo", issue
  #1504) points it at a host the *member* typed, and that difference is the
  whole reason this module is not shaped like its two siblings:

    * the instance is vetted through `Vutuv.Ssrf` before every request, so an
      entry naming an internal address can never make this server fetch it;
    * `fetch_user/1` is **public**, because that one request is also the entry's
      admission check (`Vutuv.CodeStats.verify_instance/1` refuses an account
      whose instance does not answer for that username) and the source of the
      `website` / `description` fields
      `Vutuv.Profiles.SocialAccountVerification` reads as a proof. One request,
      three readers — an instance is never asked the same question twice.
  """

  require Logger

  alias Vutuv.CodeStats.Snapshot
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Ssrf

  # A Gitea/Forgejo username: alphanumeric with dots, dashes and underscores.
  # Only this shape may be embedded in the API paths.
  @handle_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  # Codeberg keeps its own key and passes it in, so a test never intercepts the
  # other host's requests by accident.
  @req_options :forgejo_req_options

  @doc "The username grammar both forges share, for a client that builds its own paths."
  def handle_format, do: @handle_format

  @doc """
  The blocking fetch for a **self-hosted** account, whose value carries its own
  instance (`name@git.example.com`): `{:ok, stats_map}` or a classified
  `{:error, :gone | :transient}`.
  """
  def fetch_stats(value) do
    with {:ok, handle, api} <- instance(value), do: fetch_stats(handle, api, @req_options)
  end

  @doc """
  The same fetch against an explicit API base (`https://host/api/v1`) and
  req-options seam — what `Vutuv.CodeStats.Codeberg` calls with its fixed host.
  """
  def fetch_stats(handle, api, options_key) do
    with {:ok, handle} <- Snapshot.validate_handle(handle, @handle_format),
         {:ok, user} when is_map(user) <- get_user(api, handle, options_key),
         {:ok, repos, total} when is_list(repos) <- fetch_repos(api, handle, options_key) do
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
      Logger.warning("forgejo stats fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  @doc """
  The instance's public answer for one self-hosted `name@host` value:
  `{:ok, user_map}`, `{:error, :gone}` (no such user there, a malformed value,
  or an address this installation refuses to fetch) or `{:error, :transient}`
  (the instance could not be reached, or answered something we cannot read).

  Keeping "the instance says no such user" apart from "we could not ask" is the
  point: the first is a verdict the member can act on, the second must never be
  reported as one — the same distinction the verification re-check depends on.
  """
  def fetch_user(value) do
    with {:ok, handle, api} <- instance(value),
         {:ok, handle} <- Snapshot.validate_handle(handle, @handle_format) do
      get_user(api, handle, @req_options)
    end
  rescue
    error ->
      Logger.warning("forgejo user fetch for #{inspect(value)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  # The member-supplied instance, vetted before anything is sent to it. A
  # malformed value or an internal address is `:gone` rather than `:transient`:
  # neither is coming back, so the account is deactivated instead of walking the
  # backoff ladder against an address we will always refuse.
  #
  # `resolves_to_internal?/1` checks rather than pins (the avatar fetch in
  # Vutuv.SocialFeed.Http makes the same trade): a DNS rebind between this
  # lookup and Req's own is the acknowledged residual, and what it buys — an
  # ordinary https request with the right SNI and Host header to somebody else's
  # forge — is what this feature is.
  defp instance(value) do
    with {:ok, handle, host} <- SocialMediaAccount.split_self_hosted(value),
         false <- Ssrf.resolves_to_internal?(host) do
      {:ok, handle, "https://" <> host <> "/api/v1"}
    else
      _refused -> {:error, :gone}
    end
  end

  defp get_user(api, handle, options_key) do
    case Http.get(api <> "/users/#{handle}", options_key) do
      {:ok, %Req.Response{status: 200, body: body}} -> Snapshot.decode_or_transient(body)
      {:ok, %Req.Response{status: 404}} -> {:error, :gone}
      _other -> {:error, :transient}
    end
  end

  # The repository listing carries the x-total-count header for the full count
  # beyond this page.
  defp fetch_repos(api, handle, options_key) do
    case Http.get(api <> "/users/#{handle}/repos?limit=50", options_key) do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        with {:ok, repos} when is_list(repos) <- Snapshot.decode_or_transient(body) do
          {:ok, repos, Snapshot.total_count(resp, "x-total-count") || length(repos)}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
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
