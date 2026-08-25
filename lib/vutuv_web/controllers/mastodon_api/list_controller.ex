defmodule VutuvWeb.MastodonApi.ListController do
  @moduledoc """
  The lists a client shows behind its own tabs: what you saved, what you liked,
  who follows you, who you blocked or muted, and who reacted to a status.

  Every one of these already existed on the website — a client could set a
  bookmark but never find it again, which is the sort of half-feature that
  reads as a broken app rather than a missing one.

  Every one of them is walked by id (`Vutuv.Keyset`), the same way a Mastodon
  client walks any list: the boundary goes into the query, so the hundredth
  page costs what the first one did. The website's own pagers over the same
  data stay offset-based and keep their totals and numbered pages — the two
  vocabularies want different orders, and mixing them is what silently ended
  every one of these lists at 40 rows.
  """

  use VutuvWeb, :controller

  import VutuvWeb.MastodonApi.Errors

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Keyset
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination
  alias VutuvWeb.MastodonApi.Statuses

  def bookmarks(conn, params), do: engaged(conn, params, &Posts.bookmarked_statuses/2)
  def favourites(conn, params), do: engaged(conn, params, &Posts.liked_statuses/2)

  def followers(conn, %{"id" => id} = params) do
    page = Pagination.params(params)

    accounts =
      case UUIDv7.with_cast(id, &Accounts.get_user/1) do
        %User{} = user ->
          user
          |> Social.follow_accounts(:followers, Pagination.opts(page))
          |> Enum.map(&Presenter.account/1)

        nil ->
          []
      end

    respond(conn, accounts, page)
  end

  def blocks(conn, params) do
    page = Pagination.params(params)

    accounts =
      conn.assigns.current_user.id
      |> Social.blocked_user_ids()
      |> MapSet.to_list()
      |> blocked_accounts(page)
      |> Enum.map(&Presenter.account/1)

    respond(conn, accounts, page)
  end

  # A mute lives on the follow edge, so only somebody you follow can be muted —
  # which is also true on the website. Read straight off the edge: fetching the
  # follow list and asking `follow_edge/2` per row was a query per person on
  # the page, and it could only ever see page one of that list.
  def mutes(conn, params) do
    page = Pagination.params(params)

    accounts =
      conn.assigns.current_user
      |> Social.muted_accounts(Pagination.opts(page))
      |> Enum.map(&Presenter.account/1)

    respond(conn, accounts, page)
  end

  def favourited_by(conn, %{"id" => id} = params),
    do: reactors(conn, id, params, &Posts.post_liker_accounts/2)

  def reblogged_by(conn, %{"id" => id} = params),
    do: reactors(conn, id, params, &Posts.post_reposter_accounts/2)

  # Who reacted is only answerable for a status the asker may read: the list
  # would otherwise say who engaged with a post they cannot see, which is a
  # roundabout way of reading a restricted audience.
  defp reactors(conn, id, params, reader) do
    page = Pagination.params(params)

    case Statuses.visible(conn, id) do
      nil ->
        not_found(conn)

      %Post{} = post ->
        accounts =
          post.id
          |> reader.(Pagination.opts(page))
          |> Enum.map(&Presenter.account/1)

        respond(conn, accounts, page)

      _cached_remote_object ->
        # A cached copy of somebody else's status. Who reacted to it is the
        # origin's answer, not ours, and the reactions this installation holds
        # are only the slice that happened to reach it — so the honest answer is
        # the empty list rather than a partial one presented as the whole.
        respond(conn, [], page)
    end
  end

  @doc """
  vutuv has no custom emoji, and a client asks for them while starting up.
  An empty list is the correct answer; letting the request fall into the
  host's 404 catch-all only fills client logs with an error that means nothing.
  """
  def custom_emojis(conn, _params), do: json(conn, [])

  defp engaged(conn, params, reader) do
    page = Pagination.params(params)

    statuses =
      conn.assigns.current_user
      |> reader.(Pagination.opts(page))
      |> Presenter.statuses(conn.assigns.current_user)

    conn
    |> Pagination.link_header(Enum.map(statuses, & &1.id), page)
    |> json(statuses)
  end

  defp respond(conn, accounts, page) do
    conn
    |> Pagination.link_header(Enum.map(accounts, & &1.id), page)
    |> json(accounts)
  end

  defp blocked_accounts([], _page), do: []

  defp blocked_accounts(ids, page) do
    from(u in User, where: u.id in ^ids)
    |> Keyset.scope(Pagination.opts(page))
    |> Repo.all()
    |> Keyset.restore(Pagination.opts(page))
  end
end
