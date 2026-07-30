defmodule VutuvWeb.PostReviewComposerTest do
  @moduledoc """
  The composer no longer offers the book/film review form: the 📖/🎬 triggers,
  the panel and the ISBN lookup are gone (removed 2026-07-30). Existing review
  posts (`Vutuv.Posts.PostReview`) keep rendering their card everywhere, and
  editing such a post must leave its stored review untouched — the composer
  simply submits no `review` key any more, which the changeset reads as "leave
  it as it is".
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
    "medium" => "print"
  }

  describe "the feed composer" do
    test "renders no review triggers, panel or fields", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      {:ok, live, _html} = live(conn, ~p"/feed")

      live |> element("#open-composer") |> render_click()
      form_html = live |> element("#composer-form") |> render()

      refute form_html =~ "review-kind"
      refute form_html =~ "post[review]"
      refute has_element?(live, "#composer-review-panel")
    end
  end

  describe "stored reviews" do
    test "a review post still renders its card in the feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, _post} =
        Posts.create_post(user, %{body: "Sehr lesenswert.", review: @review_params})

      {:ok, live, _html} = live(conn, ~p"/feed")

      feed_html = live |> element("#feed-posts") |> render()
      assert feed_html =~ "data-review-card"
      assert feed_html =~ "Refactoring"
      assert feed_html =~ "Martin Fowler"
    end

    test "editing a review post keeps the review", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, post} =
        Posts.create_post(user, %{body: "Besprochen", review: @review_params})

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/edit")

      refute html =~ "composer-review-panel"
      refute html =~ "post[review]"

      live
      |> form("#composer-form", %{"post" => %{"body" => "Besprochen, immer noch gut."}})
      |> render_submit()

      updated = Posts.get_post(post.id)
      assert updated.body == "Besprochen, immer noch gut."
      assert updated.review.title == "Refactoring"
      assert updated.review.kind == "book"
    end
  end
end
