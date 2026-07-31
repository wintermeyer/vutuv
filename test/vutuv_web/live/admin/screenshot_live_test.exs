defmodule VutuvWeb.Admin.ScreenshotLiveTest do
  @moduledoc """
  The admin link-screenshot view (`/admin/screenshots`): admins-only, a Queue
  tab (unfinished jobs), a Gallery tab (captured screenshots linked to their
  posts), both paginated, and the Blocklist tab that edits which pages this
  installation never captures.

  Not async: the blocklist tab's tests rewrite the seeded
  `screenshot_blocklist_entries` rows, which concurrent modules would convoy on
  (see `Vutuv.ScreenshotBlocklistTest`).
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Repo
  alias Vutuv.ScreenshotBlocklist

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

    test "a failed job can be handed back to the worker", %{conn: conn} do
      job =
        screenshot(
          status: "failed",
          attempts: Screenshots.max_attempts(),
          last_error: ":timeout"
        )

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots")

      view |> element("#job-#{job.id} button[phx-click=requeue]") |> render_click()

      requeued = Repo.get!(PostScreenshot, job.id)
      assert requeued.status == "pending"
      assert requeued.attempts == 0
    end

    test "a job still being worked on offers no retry button", %{conn: conn} do
      job = screenshot(status: "pending", attempts: 1)

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots")

      refute has_element?(view, "#job-#{job.id} button[phx-click=requeue]")
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

  describe "blocklist tab" do
    setup %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      %{conn: conn}
    end

    test "lists the entries this installation is seeded with", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      [entry] = Enum.filter(ScreenshotBlocklist.list_entries(), &(&1.pattern == "heise.de"))
      assert has_element?(view, "#blocklist-entry-#{entry.id}")
    end

    test "an admin adds a page and it stops being captured at once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      refute ScreenshotBlocklist.blocked?("https://consent.example/page")

      view
      |> form("#blocklist-form", entry: %{pattern: "consent.example", note: "Cookie banner"})
      |> render_submit()

      assert ScreenshotBlocklist.blocked?("https://consent.example/page")
      assert render(view) =~ "consent.example"
    end

    test "an entry that names no host is refused with an error, not stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      before = length(ScreenshotBlocklist.list_entries())

      view |> form("#blocklist-form", entry: %{pattern: "https://"}) |> render_submit()

      assert has_element?(view, "#blocklist-form .editform__error")
      assert length(ScreenshotBlocklist.list_entries()) == before
    end

    test "an admin removes an entry and that site is captured again", %{conn: conn} do
      {:ok, entry} = ScreenshotBlocklist.create_entry(%{"pattern" => "gone.example"})

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      view
      |> element("#blocklist-entry-#{entry.id} button[phx-click=delete-entry]")
      |> render_click()

      refute has_element?(view, "#blocklist-entry-#{entry.id}")
      refute ScreenshotBlocklist.blocked?("https://gone.example/x")
    end

    test "the check box answers what the list covers for a real URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      view
      |> form("#blocklist-check-form", url: "https://www.heise.de/news/story-1.html")
      |> render_change()

      assert has_element?(view, "#blocklist-check-result")
      assert render(view) =~ "no screenshot is taken"

      view |> form("#blocklist-check-form", url: "https://example.com/page") |> render_change()

      assert render(view) =~ "captured as usual"
    end

    test "the tab reads in German for a German admin", %{conn: conn} do
      # A one-word label is exactly what `gettext.extract --merge` fuzzy-fills
      # with something unrelated ("Blocklist" first arrived as "Blockieren"),
      # and nothing in the build would have noticed.
      body =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/admin/screenshots?tab=blocklist")
        |> html_response(200)

      assert body =~ "Blockliste"
      assert body =~ "Domain oder URL"
      assert body =~ "URL testen"
      assert body =~ "Jetzt entfernen"
    end

    test "the cleanup drops the screenshots taken before an entry existed", %{conn: conn} do
      blocked = screenshot(status: "ready", url: "https://heise.de/x", screenshot: "aaa111.avif")
      kept = ready_screenshot()

      {:ok, view, _html} = live(conn, ~p"/admin/screenshots?tab=blocklist")

      view |> element("#blocklist-purge") |> render_click()

      refute Repo.get(PostScreenshot, blocked.id)
      assert Repo.get(PostScreenshot, kept.id)
    end
  end
end
