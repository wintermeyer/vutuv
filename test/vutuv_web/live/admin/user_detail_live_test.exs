defmodule VutuvWeb.Admin.UserDetailLiveTest do
  @moduledoc """
  The admin member detail page (`/admin/users/:id`, issue #934): admins-only,
  showing one member's account status and their **jobs footprint** (live/total
  postings, cold-outreach counter, open job-related cases) with links to the
  member's preference overrides, their postings on the jobs board, and their
  public profile. This is where the member-browser rows now land.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.JobsHelpers

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      member = insert(:activated_user)
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/users/#{member.id}"), 403)
    end
  end

  describe "detail page" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "shows the member's name, status pill and links to profile + preferences", %{conn: conn} do
      member =
        insert(:activated_user,
          first_name: "Ada",
          last_name: "Lovelace",
          username: "adalovelace"
        )

      {:ok, lv, html} = live(conn, ~p"/admin/users/#{member.id}")

      assert html =~ "Ada Lovelace"
      # email-confirmed member carries the PIN registration pill
      assert html =~ "PIN"
      assert has_element?(lv, ~s(#member-profile-link[href="/adalovelace"]))

      assert has_element?(
               lv,
               ~s(#member-prefs-link[href="/admin/users/#{member.id}/preferences"])
             )
    end

    test "counts the member's live and total postings", %{conn: conn} do
      member = poster_fixture(username: "recruiterrita")
      publish_job!(member, %{"title" => "Senior Gopher"})

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")

      assert has_element?(lv, "#jobs-footprint")
      assert lv |> element("#footprint-active") |> render() =~ "1"
      assert lv |> element("#footprint-total") |> render() =~ "1"
    end

    test "shows the cold-outreach counter against the configured limit", %{conn: conn} do
      member = insert(:activated_user)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")

      assert lv |> element("#footprint-cold") |> render() =~
               "0 / #{Vutuv.Chat.new_conversation_limit()}"
    end

    test "links to the member's postings on the jobs board", %{conn: conn} do
      member = insert(:activated_user, username: "recruiterrita")

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member.id}")

      assert lv
             |> element("#member-postings-link")
             |> render() =~ "recruiterrita"
    end

    test "a missing member id redirects back to the browser", %{conn: conn} do
      id = Vutuv.UUIDv7.generate()
      assert {:error, {:redirect, %{to: "/admin/users"}}} = live(conn, ~p"/admin/users/#{id}")
    end

    test "a malformed id redirects back to the browser instead of 500ing", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin/users"}}} =
               live(conn, ~p"/admin/users/not-a-uuid")
    end
  end

  describe "localization" do
    test "renders the footprint labels in German", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)
      member = poster_fixture()

      # The dead render goes through the locale plug; the German words prove it is
      # the German render, not an English fallback masking a missing translation.
      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/admin/users/#{member.id}")
        |> html_response(200)

      assert html =~ "Aktive Anzeigen"
      assert html =~ "Kaltakquise"
    end
  end
end
