defmodule VutuvWeb.MastodonApi.ListController do
  @moduledoc """
  The lists a client shows behind its own tabs: what you saved, what you liked,
  who follows you, who you blocked or muted, and who reacted to a status.

  Every one of these already existed on the website — a client could set a
  bookmark but never find it again, which is the sort of half-feature that
  reads as a broken app rather than a missing one.

  Paging is `Vutuv.Pages`' offset underneath and Mastodon's id walk on top:
  these readers take an `offset`, not a keyset, so a page is fetched with
  headroom and `Pagination.window/3` cuts it on the ids. That keeps one
  vocabulary at the edge without rewriting four readers underneath.
  """

  use VutuvWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination

  def bookmarks(conn, params), do: engaged(conn, params, &Posts.bookmarked_posts_page/2)
  def favourites(conn, params), do: engaged(conn, params, &Posts.liked_posts_page/2)

  def followers(conn, %{"id" => id} = params) do
    page = Pagination.params(params)

    accounts =
      case UUIDv7.with_cast(id, &Accounts.get_user/1) do
        %User{} = user ->
          user
          |> Social.follows_page(:followers, %{})
          |> Map.fetch!(:users)
          |> Enum.sort_by(& &1.id, :desc)
          |> Pagination.window(page, & &1.id)
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
      |> users_by_ids()
      |> Pagination.window(page, & &1.id)
      |> Enum.map(&Presenter.account/1)

    respond(conn, accounts, page)
  end

  # A mute lives on the follow edge, so only somebody you follow can be muted —
  # which is also true on the website.
  def mutes(conn, params) do
    page = Pagination.params(params)

    accounts =
      conn.assigns.current_user
      |> Social.follows_page(:followees, %{})
      |> Map.fetch!(:users)
      |> Enum.filter(&muted?(conn.assigns.current_user.id, &1.id))
      |> Enum.sort_by(& &1.id, :desc)
      |> Pagination.window(page, & &1.id)
      |> Enum.map(&Presenter.account/1)

    respond(conn, accounts, page)
  end

  def favourited_by(conn, %{"id" => id} = params),
    do: reactors(conn, id, params, &Posts.post_likers(&1, limit: &2))

  def reblogged_by(conn, %{"id" => id} = params),
    do: reactors(conn, id, params, &reposters/2)

  # Who reacted is only answerable for a status the asker may read: the list
  # would otherwise say who engaged with a post they cannot see, which is a
  # roundabout way of reading a restricted audience.
  defp reactors(conn, id, params, reader) do
    page = Pagination.params(params)
    viewer = conn.assigns.current_organization || conn.assigns.current_user

    case visible_post(id, viewer) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Record not found"})

      post ->
        accounts =
          post.id
          |> reader.(Pagination.fetch_size(page))
          |> Pagination.window(page, & &1.id)
          |> Enum.map(&Presenter.account/1)

        respond(conn, accounts, page)
    end
  end

  defp visible_post(id, viewer) do
    case Posts.get_post(id) do
      %Post{} = post -> if Posts.visible_to?(post, viewer), do: post
      nil -> nil
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
      |> reader.(limit: Pagination.fetch_size(page))
      |> Map.fetch!(:entries)
      |> Pagination.window(page, & &1.id)
      |> Enum.map(&Presenter.status/1)

    conn
    |> Pagination.link_header(Enum.map(statuses, & &1.id), page)
    |> json(statuses)
  end

  defp respond(conn, accounts, page) do
    conn
    |> Pagination.link_header(Enum.map(accounts, & &1.id), page)
    |> json(accounts)
  end

  defp reposters(post_id, limit) do
    Repo.all(
      from(r in PostRepost,
        join: u in User,
        on: u.id == r.user_id,
        where: r.post_id == ^post_id,
        order_by: [desc: r.id],
        limit: ^limit,
        select: u
      )
    )
  end

  defp users_by_ids([]), do: []

  defp users_by_ids(ids) do
    Repo.all(from(u in User, where: u.id in ^ids, order_by: [desc: u.id]))
  end

  defp muted?(user_id, target_id) do
    match?(%{muted?: true}, Social.follow_edge(user_id, target_id))
  end
end
