defmodule VutuvWeb.UserProfileBookwyrmTest do
  @moduledoc """
  The profile's "Book reviews" card, fed by a listed BookWyrm account. Not
  async: it flips `:fetch_bookwyrm_posts` and stubs `:bookwyrm_req_options`,
  both read by `Vutuv.SocialFeed` for every profile mount, and the app-wide
  social feed cache is shared. Every test uses its own handle so that cache
  cannot leak between them.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.SocialFeed.Book
  alias Vutuv.SocialFeed.Cache
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Post

  @section "#profile-book-reviews"

  defp unique_handle, do: "alice#{System.unique_integer([:positive])}@books.example"

  setup do
    Application.put_env(:vutuv, :fetch_bookwyrm_posts, true)
    on_exit(fn -> Application.put_env(:vutuv, :fetch_bookwyrm_posts, false) end)

    # The mount-time fetch fails, so every test hands the view its reviews as
    # the cache message the real fetch would send.
    Application.put_env(:vutuv, :bookwyrm_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :bookwyrm_req_options) end)
    Cache.reset()
    on_exit(fn -> Cache.reset() end)
    :ok
  end

  defp owner_with_bookwyrm(handle, user_attrs \\ []) do
    owner = insert_activated_user(user_attrs)
    insert(:social_media_account, provider: "BookWyrm", value: handle, user: owner)
    owner
  end

  defp review(n, book_attrs) do
    %Post{
      id: "https://books.example/user/alice/review/#{n}",
      url: "https://books.example/user/alice/review/#{n}",
      text: "Ein großer Lesespaß, Nummer #{n}.",
      created_at: DateTime.add(~U[2026-06-08 14:42:00Z], -n, :day),
      book:
        struct(
          %Book{title: "Buch #{n}", author: "Wolf Haas", rating: 5.0, headline: "Titel #{n}"},
          book_attrs
        )
    }
  end

  defp feed(handle, posts) do
    %Feed{
      name: "Alice Liest",
      handle: handle,
      url: "https://books.example/user/alice",
      posts: posts
    }
  end

  defp deliver(view, handle, posts) do
    send(view.pid, {:social_feed_posts, "BookWyrm", handle, {:ok, feed(handle, posts)}})
    render(view)
  end

  test "the reviews get a card of their own, never the social posts card", %{conn: conn} do
    handle = unique_handle()
    owner = owner_with_bookwyrm(handle)
    {:ok, view, _html} = live(conn, ~p"/#{owner}")
    refute has_element?(view, @section)

    html =
      deliver(view, handle, [
        review(1, cover: "data:image/jpeg;base64,/9j/"),
        review(2, rating: 3.5)
      ])

    assert has_element?(view, @section)
    refute has_element?(view, "#profile-social-posts")
    assert html =~ "Buch 1"
    assert html =~ "Wolf Haas"
    assert html =~ "Titel 1"
    assert html =~ "Ein großer Lesespaß, Nummer 1."

    assert has_element?(
             view,
             ~s(#{@section} a[href="https://books.example/user/alice/review/1"])
           )

    assert has_element?(view, ~s(#{@section} img[src^="data:image/jpeg;base64,"]))
    assert has_element?(view, ~s(#{@section} [data-rating="5.0"]))
    assert has_element?(view, ~s(#{@section} [data-rating="3.5"]))
    assert has_element?(view, ~s(#{@section} a[href="https://books.example/user/alice"]))
  end

  test "a review without stars or cover renders neither", %{conn: conn} do
    handle = unique_handle()
    owner = owner_with_bookwyrm(handle)
    {:ok, view, _html} = live(conn, ~p"/#{owner}")

    deliver(view, handle, [review(1, rating: nil, headline: nil, author: nil)])

    assert has_element?(view, @section)
    refute has_element?(view, ~s(#{@section} [data-rating]))
    refute has_element?(view, ~s(#{@section} img))
  end

  test "an account without reviews shows no card", %{conn: conn} do
    handle = unique_handle()
    owner = owner_with_bookwyrm(handle)
    {:ok, view, _html} = live(conn, ~p"/#{owner}")

    deliver(view, handle, [])

    refute has_element?(view, @section)
  end

  test "the owner's opt-out hides the reviews too", %{conn: conn} do
    handle = unique_handle()
    owner = owner_with_bookwyrm(handle, show_mastodon_feed?: false)
    {:ok, view, _html} = live(conn, ~p"/#{owner}")

    deliver(view, handle, [review(1, %{})])

    refute has_element?(view, @section)
  end

  test "the card reads German for a German visitor", %{conn: conn} do
    handle = unique_handle()
    owner = owner_with_bookwyrm(handle)
    conn = put_req_header(conn, "accept-language", "de-DE,de")
    {:ok, view, _html} = live(conn, ~p"/#{owner}")

    html = deliver(view, handle, [review(1, rating: 4.0)])

    assert html =~ "Buchrezensionen"
    assert html =~ "Alle Rezensionen auf books.example"
    assert html =~ "4 von 5 Sternen"
  end
end
