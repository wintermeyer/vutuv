defmodule VutuvWeb.MastodonApi.SearchController do
  @moduledoc "Account lookup used by Mastodon clients before following someone."

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias VutuvWeb.MastodonApi.Handles

  def search(conn, %{"q" => query} = params) do
    query = String.trim(query)
    limit = limit(params)
    type = params["type"]

    resolved = query |> resolve(conn) |> List.wrap() |> Enum.reject(&is_nil/1)
    free_text = if params["resolve"] in [true, "true", "1"], do: nil, else: instant(conn, query)

    json(conn, %{
      accounts: section(type, "accounts", fn -> accounts(resolved, free_text, limit) end),
      statuses: section(type, "statuses", fn -> statuses(free_text, limit, viewer(conn)) end),
      hashtags: section(type, "hashtags", fn -> hashtags(free_text, limit, viewer(conn)) end)
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

  # Preloaded before rendering, because `Vutuv.Search` loads only what a result
  # *row* on the website needs — it preloads the two author sides and nothing
  # else. Every other list in this adapter arrives through a reader that has
  # already run `post_preloads/0`, so the presenter is written for loaded posts
  # and answers an unloaded association by leaving the thing out: no
  # `media_attachments`, no inline pictures in the body, and `in_reply_to_id`
  # nil, which renders a reply as though it opened its own conversation. None of
  # that errors, so search quietly served a thinner post than every other
  # endpoint. `Repo.preload/2` skips what is already loaded, so the authors are
  # not fetched twice.
  defp statuses(%{posts: posts}, limit, viewer) when is_list(posts) do
    posts
    |> Enum.take(limit)
    |> Repo.preload(Posts.render_preloads())
    |> Presenter.statuses(viewer)
  end

  defp statuses(_no_free_text, _limit, _viewer), do: []

  defp viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  # Mastodon's Tag entity, rendered by the one owner of that shape
  # (`Presenter.tag/2`) so the search results, `/api/v1/tags/:id` and
  # `/api/v1/followed_tags` cannot describe the same topic differently.
  #
  # `following` used to be a hardcoded `false`, which is a claim and not a
  # placeholder: a client draws its Follow button from it, so a topic the member
  # already follows was offered to them again. One query per search fills it for
  # the whole page.
  defp hashtags(%{tags: tags}, limit, viewer) when is_list(tags) do
    followed = followed_tag_ids(viewer)

    tags
    |> Enum.take(limit)
    |> Enum.map(&Presenter.tag(&1, MapSet.member?(followed, &1.id)))
  end

  defp hashtags(_no_free_text, _limit, _viewer), do: []

  # A page identity follows topics of its own, but a search runs for whoever is
  # reading; answering with the page's subscriptions would tick a box the member
  # never ticked, so an `%Organization{}` falls through to the empty set.
  defp followed_tag_ids(%User{} = user), do: user |> Tags.followed_tag_ids() |> MapSet.new()
  defp followed_tag_ids(_page_identity), do: MapSet.new()

  defp limit(%{"limit" => value}) do
    case Integer.parse(to_string(value)) do
      {limit, _rest} -> limit |> max(1) |> min(40)
      :error -> 20
    end
  end

  defp limit(_params), do: 20

  defp resolve(query, conn), do: Handles.resolve(conn, query)
end
