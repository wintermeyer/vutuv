defmodule VutuvWeb.Admin.MediaLiveTest do
  @moduledoc """
  The media-job log at `/admin/media` (issue #2103): admin-only, one search
  over member, kind and outcome, a sort on every column and numbered paging.

  The German assertion is not decoration — this is a German site, and a page
  whose labels are all brand-new msgids is exactly the shape
  `mix gettext.extract --merge` fuzzy-fills with some unrelated translation.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.MediaJobs

  test "an ordinary member cannot open it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn = get(conn, ~p"/admin/media")
    assert conn.status == 403
  end

  test "an anonymous visitor cannot open it", %{conn: conn} do
    conn = get(conn, ~p"/admin/media")
    assert redirected_to(conn) == ~p"/"
  end

  describe "the table" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)

      anna = insert(:user, username: "media-live-anna", first_name: "Anna")
      post = insert(:post, user: anna)

      scan =
        MediaJobs.start("image_scan",
          subject_type: "image_scan",
          subject_id: Vutuv.UUIDv7.generate(),
          user_id: anna.id,
          post_id: post.id
        )

      :ok = MediaJobs.finish(scan, detail: "safe")

      shot = MediaJobs.start("screenshot")
      :ok = MediaJobs.fail(shot, :bad_status)

      running = MediaJobs.start("video_conversion")

      %{
        conn: conn,
        admin: admin,
        anna: anna,
        post: post,
        scan: scan.id,
        shot: shot.id,
        running: running.id
      }
    end

    test "lists every job, with what it worked on and how it ended", %{
      conn: conn,
      scan: scan,
      shot: shot,
      running: running
    } do
      {:ok, live, _html} = live(conn, ~p"/admin/media")

      rows = live |> element("#media-jobs") |> render()

      assert rows =~ "media-live-anna"
      assert rows =~ "safe"
      assert rows =~ "bad_status"

      for id <- [scan, shot, running], do: assert(has_element?(live, "#media-job-#{id}"))
    end

    test "a job's post is a link to the post", %{conn: conn, post: post} do
      {:ok, live, _html} = live(conn, ~p"/admin/media")

      assert has_element?(live, "#media-jobs a[href='#{Vutuv.Posts.path(post)}']")
    end

    test "the search narrows by member and rides the URL", %{conn: conn, scan: scan, shot: shot} do
      {:ok, live, _html} = live(conn, ~p"/admin/media")

      live |> element("#media-filter") |> render_change(%{"q" => "media-live-anna"})

      assert has_element?(live, "#media-job-#{scan}")
      refute has_element?(live, "#media-job-#{shot}")
      assert_patched(live, ~p"/admin/media?q=media-live-anna")
    end

    test "the search narrows by kind", %{conn: conn, running: running, scan: scan} do
      {:ok, live, _html} = live(conn, ~p"/admin/media?q=video_conversion")

      assert has_element?(live, "#media-job-#{running}")
      refute has_element?(live, "#media-job-#{scan}")
    end

    test "the search narrows by outcome", %{conn: conn, shot: shot, scan: scan} do
      {:ok, live, _html} = live(conn, ~p"/admin/media?q=failed")

      assert has_element?(live, "#media-job-#{shot}")
      refute has_element?(live, "#media-job-#{scan}")
    end

    test "a search that matches nothing says so", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/media?q=nothing-matches-this")

      assert has_element?(live, "#no-media-jobs")
      assert has_element?(live, "#clear-filters")
    end

    test "every column header sorts, and the sort rides the URL", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/admin/media")

      for col <- ~w(started member kind outcome duration) do
        assert has_element?(live, "#sort-#{col}")
      end

      live |> element("#sort-kind") |> render_click()
      assert_patched(live, ~p"/admin/media?sort=kind")

      # A second click on the active column turns it round.
      live |> element("#sort-kind") |> render_click()
      assert_patched(live, ~p"/admin/media?dir=desc&sort=kind")
    end

    test "sorting by member keeps the ownerless jobs on the page", %{conn: conn, shot: shot} do
      {:ok, live, _html} = live(conn, ~p"/admin/media?sort=member")

      assert has_element?(live, "#media-job-#{shot}")
    end

    test "a page beyond the end falls back to the first page", %{conn: conn, scan: scan} do
      {:ok, live, _html} = live(conn, ~p"/admin/media?page=99")

      assert has_element?(live, "#media-job-#{scan}")
    end

    test "the paging line counts the whole list", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/admin/media")

      assert html =~ "1-3"
    end

    test "the page speaks German to a German browser", %{conn: conn} do
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      {:ok, _live, html} = live(conn, ~p"/admin/media")

      assert html =~ "Medienaufträge"
      assert html =~ "Gestartet"
      assert html =~ "Gedauert"
      assert html =~ "Fehlgeschlagen"
      assert html =~ "Läuft"
    end
  end

  describe "durations" do
    setup %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      %{conn: conn}
    end

    test "a finished job shows how long it took, spelled out", %{conn: conn} do
      job = MediaJobs.start("screenshot")

      # 3 minutes 7 seconds, stamped past the row so the reading is a fixed one.
      job
      |> Ecto.Changeset.change(%{
        started_at: DateTime.add(job.started_at, -187, :second),
        finished_at: job.started_at,
        status: "done"
      })
      |> Vutuv.Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/admin/media")
      row = live |> element("#media-job-#{job.id}") |> render()

      assert row =~ "3 min 7 s"
      refute row =~ "187000"
    end

    test "a running job's duration counts from its start rather than reading nothing", %{
      conn: conn
    } do
      job = MediaJobs.start("video_conversion")

      job
      |> Ecto.Changeset.change(%{started_at: DateTime.add(DateTime.utc_now(), -7_200, :second)})
      |> Vutuv.Repo.update!()

      {:ok, live, _html} = live(conn, ~p"/admin/media")

      assert live |> element("#media-job-#{job.id}") |> render() =~ "2 h"
    end
  end
end
