defmodule VutuvWeb.Admin.ScreenshotLiveTest do
  @moduledoc """
  The admin link-screenshot view (`/admin/screenshots`): admins-only, a Queue
  tab (unfinished jobs) and a Gallery tab (captured screenshots linked to their
  posts), both paginated.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo

  defp post_for(author) do
    Repo.insert!(%Post{
      user_id: author.id,
      body: "https://shot.test",
      published_on: Vutuv.BerlinTime.today()
    })
  end

  defp screenshot(attrs) do
    author = insert(:activated_user)
    post = post_for(author)

    Repo.insert!(
      struct(
        %PostScreenshot{
          post_id: post.id,
          url: "https://shot.test",
          status: "pending"
        },
        attrs
      )
    )
  end

  defp ready_screenshot do
    screenshot(status: "ready", screenshot: "abcdef012345.avif", captured_at: now())
  end

  defp now, do: DateTime.utc_now(:second)

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/screenshots"), 403)
    end
  end

  describe "queue tab" do
    setup %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      %{conn: conn}
    end

    test "lists an unfinished job with a link to its post", %{conn: conn} do
      job = screenshot(status: "failed", attempts: 3, last_error: ":timeout")

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots")

      assert has_element?(view, "#job-#{job.id}")
      assert has_element?(view, "#job-#{job.id} a", "@")
    end

    test "does not list a ready job in the queue", %{conn: conn} do
      ready = ready_screenshot()

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots")

      refute has_element?(view, "#job-#{ready.id}")
    end
  end

  describe "gallery tab" do
    setup %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      %{conn: conn}
    end

    test "lists a captured screenshot linked to its post", %{conn: conn} do
      ready = ready_screenshot()

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=gallery")

      assert has_element?(view, "#screenshot-#{ready.id}")
      assert has_element?(view, "#screenshot-#{ready.id} img")
    end

    test "paginates when there are more than one page of screenshots", %{conn: conn} do
      for _ <- 1..(Screenshots.per_page() + 1), do: ready_screenshot()

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=gallery")

      assert has_element?(view, "nav[aria-label]")
    end
  end
end
