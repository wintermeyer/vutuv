defmodule VutuvWeb.PostReviewComposerTest do
  @moduledoc """
  The composer's review panel (book/film reviews, `Vutuv.Posts.PostReview`):
  opening it via the 📖/🎬 triggers, the ISBN lookup prefill, the save round
  trip onto the feed card, and removing a stored review from the edit page.
  """

  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  @review_params %{
    "kind" => "book",
    "identifier" => "978-3-16-148410-0",
    "title" => "Refactoring",
    "creator" => "Martin Fowler",
    "year" => "2018",
    "medium" => "audiobook"
  }

  describe "the feed composer" do
    test "opens the panel, saves a book review and renders the card", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      refute has_element?(live, "#composer-review-panel")

      live
      |> element(~s(button[phx-click="review-kind"][phx-value-kind="book"]))
      |> render_click()

      assert has_element?(live, "#composer-review-panel")

      live
      |> form("#composer-form", %{
        "post" => %{"body" => "Sehr lesenswert.", "review" => @review_params}
      })
      |> render_submit()

      feed_html = live |> element("#feed-posts") |> render()
      assert feed_html =~ "data-review-card"
      assert feed_html =~ "Refactoring"
      assert feed_html =~ "Martin Fowler"
      assert feed_html =~ "978-3-16-148410-0"
      assert feed_html =~ "https://www.amazon.de/dp/316148410X"

      # The composer reset also closes the panel for the next post.
      refute has_element?(live, "#composer-review-panel")
    end

    test "a film review stores the IMDb id and links IMDb", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(button[phx-click="review-kind"][phx-value-kind="movie"]))
      |> render_click()

      live
      |> form("#composer-form", %{
        "post" => %{
          "body" => "Starker Film.",
          "review" => %{
            "kind" => "movie",
            "identifier" => "https://www.imdb.com/title/tt0111161/?ref_=x",
            "title" => "Die Verurteilten",
            "creator" => "Frank Darabont",
            "medium" => "cinema"
          }
        }
      })
      |> render_submit()

      feed_html = live |> element("#feed-posts") |> render()
      assert feed_html =~ ~s(data-review-kind="movie")
      assert feed_html =~ "https://www.imdb.com/title/tt0111161/"

      _ = user
      review = Vutuv.Repo.one(Vutuv.Posts.PostReview)
      assert review.identifier == "tt0111161"
      assert review.medium == "cinema"
    end

    test "an invalid ISBN surfaces the review error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(button[phx-click="review-kind"][phx-value-kind="book"]))
      |> render_click()

      html =
        live
        |> form("#composer-form", %{
          "post" => %{
            "body" => "Kaputt",
            "review" => %{"kind" => "book", "identifier" => "12345", "title" => "X"}
          }
        })
        |> render_submit()

      assert html =~ "is not a valid ISBN"
      assert live |> element("#composer-error") |> render() =~ "is not a valid ISBN"
    end

    test "the ISBN lookup prefills title, creator and year", %{conn: conn} do
      Application.put_env(:vutuv, :fetch_book_metadata, true)

      Application.put_env(:vutuv, :book_metadata_req_options,
        plug: fn plug_conn ->
          body = %{
            "ISBN:9783161484100" => %{
              "title" => "Refactoring",
              "authors" => [%{"name" => "Martin Fowler"}],
              "publish_date" => "November 2018"
            }
          }

          plug_conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(body))
        end
      )

      on_exit(fn ->
        Application.put_env(:vutuv, :fetch_book_metadata, false)
        Application.delete_env(:vutuv, :book_metadata_req_options)
      end)

      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> element(~s(button[phx-click="review-kind"][phx-value-kind="book"]))
      |> render_click()

      live
      |> form("#composer-form", %{
        "post" => %{"review" => %{"kind" => "book", "identifier" => "978-3-16-148410-0"}}
      })
      |> render_change()

      html = live |> element("#composer-review-lookup") |> render_click()

      assert html =~ ~s(value="Refactoring")
      assert html =~ ~s(value="Martin Fowler")
      assert html =~ ~s(value="2018")
    end
  end

  describe "the edit page" do
    test "prefills the stored review and removes it via the panel's ✕", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, post} =
        Posts.create_post(user, %{body: "Besprochen", review: @review_params})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert html =~ ~s(id="composer-review-panel")
      assert html =~ ~s(value="Refactoring")

      live
      |> element(~s(#composer-review-panel button[phx-click="review-kind"][phx-value-kind=""]))
      |> render_click()

      live
      |> form("#composer-form", %{"post" => %{"body" => "Besprochen"}})
      |> render_submit()

      updated = Posts.get_post(post.id)
      assert updated.review == nil
    end
  end
end
