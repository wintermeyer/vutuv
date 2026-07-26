defmodule VutuvWeb.ComposerDraftGuardTest do
  @moduledoc """
  The composer's unsaved-draft guard (issue #1148). The composer marks itself
  `data-draft-unsaved` whenever its content differs from what it opened with,
  and the `DraftGuard` hook in `assets/js/app.js` turns that marker into the
  browser's own "Leave site?" prompt on a reload or a tab close. So the marker
  is the whole server-side contract, and these tests pin it down: an untouched
  composer must stay quiet (a guard that fires on every page is a guard people
  learn to click away), and anything the author put in by hand must arm it.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  # The composer's marker, read off its root element.
  defp guard(live) do
    html = live |> element("#composer") |> render()

    case Regex.run(~r/data-draft-unsaved="([^"]*)"/, html, capture: :all_but_first) do
      [value] -> value
      nil -> flunk("the composer renders no data-draft-unsaved marker")
    end
  end

  describe "the feed composer" do
    test "an untouched composer has nothing to lose", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      assert guard(live) == "false"
    end

    test "typed text arms the guard", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "half a thought"}})
      |> render_change()

      assert guard(live) == "true"
    end

    test "tags alone arm the guard", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "", "tags" => "elixir"}})
      |> render_change()

      assert guard(live) == "true"
    end

    test "deleting the text again disarms it", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "half a thought"}})
      |> render_change()

      live
      |> form("#composer-form", %{"post" => %{"body" => ""}})
      |> render_change()

      assert guard(live) == "false"
    end

    test "posting empties the composer and disarms the guard", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      {:ok, live, _html} = live(conn, ~p"/feed")

      live
      |> form("#composer-form", %{"post" => %{"body" => "a whole thought", "tags" => "elixir"}})
      |> render_submit()

      assert guard(live) == "false"
    end
  end

  describe "the edit page" do
    test "a prefilled composer is not a draft until it is changed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "as published", tags: "elixir"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      assert guard(live) == "false"
    end

    test "changing the body arms the guard", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "as published"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      live
      |> form("#composer-form", %{"post" => %{"body" => "as published, plus a sentence"}})
      |> render_change()

      assert guard(live) == "true"
    end

    test "changing the tags arms the guard", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "as published", tags: "elixir"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      live
      |> form("#composer-form", %{
        "post" => %{"body" => "as published", "tags" => "elixir, phoenix"}
      })
      |> render_change()

      assert guard(live) == "true"
    end

    test "typing the original text back disarms it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, post} = Posts.create_post(user, %{body: "as published"})

      {:ok, live, _html} = live(conn, ~p"/posts/#{post.id}/edit")

      live
      |> form("#composer-form", %{"post" => %{"body" => "typo"}})
      |> render_change()

      live
      |> form("#composer-form", %{"post" => %{"body" => "as published"}})
      |> render_change()

      assert guard(live) == "false"
    end
  end

  describe "the reply page" do
    test "a quoted passage the reader never typed is not an unsaved draft", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      author = insert(:user, email_confirmed?: true)
      {:ok, parent} = Posts.create_post(author, %{body: "a passage worth answering"})

      {:ok, live, html} =
        live(conn, ~p"/posts/#{parent.id}/reply?quote=a+passage+worth+answering")

      # The quote really is in the editor — it is just not the reader's own
      # work, and it comes back from the URL on a reload.
      assert html =~ "a passage worth answering"
      assert guard(live) == "false"

      live
      |> form("#composer-form", %{"post" => %{"body" => "> a passage worth answering\n\nAgreed."}})
      |> render_change()

      assert guard(live) == "true"
    end
  end
end
