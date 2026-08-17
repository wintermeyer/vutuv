defmodule VutuvWeb.MastodonApi.SearchController do
  @moduledoc "Account lookup used by Mastodon clients before following someone."

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Moderation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization

  def search(conn, %{"q" => query} = params) do
    query = String.trim(query)
    limit = limit(params)
    type = params["type"]

    resolved = query |> resolve(conn) |> List.wrap() |> Enum.reject(&is_nil/1)
    free_text = if params["resolve"] in [true, "true", "1"], do: nil, else: instant(conn, query)

    json(conn, %{
      accounts: section(type, "accounts", fn -> accounts(resolved, free_text, limit) end),
      statuses: section(type, "statuses", fn -> statuses(free_text, limit, viewer(conn)) end),
      hashtags: section(type, "hashtags", fn -> hashtags(free_text, limit) end)
    })
  end

  def search(conn, _params), do: json(conn, %{accounts: [], statuses: [], hashtags: []})

  # `type` narrows the search to one section; the others answer empty rather
  # than being computed and thrown away.
  defp section(nil, _wanted, fun), do: fun.()
  defp section(wanted, wanted, fun), do: fun.()
  defp section(_type, _wanted, _fun), do: []

  # The website's own matcher, so a phone client finds a member by name exactly
  # as the search page does — including its `tag:`/`ort:` operators and the
  # viewer scoping that keeps blocked and moderated accounts out.
  defp instant(conn, query) do
    Vutuv.Search.instant(query, viewer: conn.assigns.current_user)
  end

  defp accounts(resolved, free_text, limit) do
    people =
      case free_text do
        %{exact_people: exact, similar_people: similar} -> exact ++ similar
        _no_free_text -> []
      end

    (resolved ++ people)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
    |> Enum.map(&Presenter.account/1)
  end

  defp statuses(%{posts: posts}, limit, viewer) when is_list(posts),
    do: posts |> Enum.take(limit) |> Presenter.statuses(viewer)

  defp statuses(_no_free_text, _limit, _viewer), do: []

  defp viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  # Mastodon's Tag entity. vutuv tags live at `/tags/:slug` on the main host,
  # which is where a client's "open in browser" should land.
  defp hashtags(%{tags: tags}, limit) when is_list(tags) do
    tags
    |> Enum.take(limit)
    |> Enum.map(fn tag ->
      %{
        name: tag.slug,
        url: MastodonApi.main_url("/tags/#{tag.slug}"),
        history: [],
        following: false
      }
    end)
  end

  defp hashtags(_no_free_text, _limit), do: []

  defp limit(%{"limit" => value}) do
    case Integer.parse(to_string(value)) do
      {limit, _rest} -> limit |> max(1) |> min(40)
      :error -> 20
    end
  end

  defp limit(_params), do: 20

  defp resolve("@" <> address, conn) do
    case String.split(address, "@", parts: 2) do
      [handle] -> resolve_local(conn, handle)
      [handle, host] -> resolve_qualified(conn, address, handle, String.downcase(host))
    end
  end

  defp resolve(query, conn), do: resolve_local(conn, query)

  defp resolve_qualified(conn, address, handle, host) do
    if host in [MastodonApi.local_domain(), MastodonApi.api_host()],
      do: resolve_local(conn, handle),
      else: resolve_remote(conn, address)
  end

  defp resolve_remote(conn, address) do
    subject = conn.assigns.current_organization || conn.assigns.current_user

    case Fediverse.resolve_remote_account(subject, "@" <> address) do
      {:ok, account} -> account
      _error -> nil
    end
  end

  defp resolve_local(conn, handle) do
    normalized = String.downcase(handle)

    normalized
    |> local_account()
    |> visible_to_identity(conn)
  end

  defp local_account(handle) do
    Accounts.get_user_by_username(handle) ||
      Organizations.get_organization_by_username(handle) ||
      Organizations.get_organization_by_slug(handle)
  end

  defp visible_to_identity(%User{} = user, conn) do
    viewer = if is_nil(conn.assigns.current_organization), do: conn.assigns.current_user
    if Moderation.profile_visible_to?(user, viewer), do: user
  end

  defp visible_to_identity(%Organization{} = organization, conn) do
    current_id = conn.assigns.current_organization && conn.assigns.current_organization.id

    if Organizations.public_visible?(organization) or current_id == organization.id,
      do: organization
  end

  defp visible_to_identity(nil, _conn), do: nil
end
