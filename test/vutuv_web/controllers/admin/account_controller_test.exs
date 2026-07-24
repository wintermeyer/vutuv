defmodule VutuvWeb.Admin.AccountControllerTest do
  @moduledoc """
  The admin account freezer (issue #812): admins-only search for any account
  and a CSRF-protected freeze / unfreeze, plus a paginated frozen-accounts list.

  The freeze/unfreeze POSTs are driven through `submit_with_csrf/3` (see
  ConnCase), not a bare `post/3`, so the rendered form's CSRF token is actually
  exercised — the CSRF rule in CLAUDE.md.
  """
  use VutuvWeb.ConnCase

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.{AdminAction, Case}
  alias Vutuv.Repo

  defp frozen_actions(user_id),
    do: Repo.all(from(a in AdminAction, where: a.user_id == ^user_id))

  describe "authorization" do
    test "non-admins are locked out of the search page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/accounts"), 403)
    end

    test "non-admins are locked out of the frozen list", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert html_response(get(conn, ~p"/admin/accounts/frozen"), 403)
    end
  end

  describe "index (search)" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "shows a prompt before searching", %{conn: conn} do
      response = html_response(get(conn, ~p"/admin/accounts"), 200)
      assert response =~ "Type a name, @handle or email"
    end

    test "finds an account by name, @handle and email", %{conn: conn} do
      user = insert(:activated_user, first_name: "Zaphod", username: "zaphod")
      insert(:email, user: user, value: "beeblebrox@example.com")

      by_name = html_response(get(conn, ~p"/admin/accounts?q=Zaphod"), 200)
      assert by_name =~ "@zaphod"

      by_handle = html_response(get(conn, ~p"/admin/accounts?q=@zaphod"), 200)
      assert by_handle =~ "@zaphod"

      by_email = html_response(get(conn, ~p"/admin/accounts?q=beeblebrox@example.com"), 200)
      assert by_email =~ "@zaphod"
    end

    test "reports no matches for an empty result", %{conn: conn} do
      response = html_response(get(conn, ~p"/admin/accounts?q=nobodyhere-xyz"), 200)
      assert response =~ "No accounts match your search"
    end
  end

  describe "freeze / unfreeze" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "freezes an account through a CSRF-protected POST and audits it", %{
      conn: conn,
      admin: admin
    } do
      user = insert(:activated_user, first_name: "Freezeme", username: "freezeme")

      # Render the page so the freeze form's CSRF token is available, and assert
      # the rendered form actually posts to the freeze route (the "assert the
      # rendered action=" rule — a bare post/3 to a route I know exists would not
      # catch a form pointing at the wrong URL).
      conn = get(conn, ~p"/admin/accounts?q=freezeme")
      assert html_response(conn, 200) =~ ~s(action="/admin/accounts/#{user.id}/freeze")

      conn =
        submit_with_csrf(conn, ~p"/admin/accounts/#{user.id}/freeze", %{
          "return_to" => "/admin/accounts?q=freezeme"
        })

      assert redirected_to(conn) == "/admin/accounts?q=freezeme"
      assert Repo.get!(User, user.id).frozen_at

      assert [%AdminAction{action: "account_frozen", actor_id: actor}] = frozen_actions(user.id)
      assert actor == admin.id
    end

    test "a freeze hides the profile from anonymous visitors (403)", %{conn: conn} do
      user = insert(:activated_user, first_name: "Hideme", username: "hideme")
      conn = get(conn, ~p"/admin/accounts?q=hideme")

      submit_with_csrf(conn, ~p"/admin/accounts/#{user.id}/freeze", %{
        "return_to" => "/admin/accounts"
      })

      assert get(build_conn(), "/hideme").status == 403
    end

    test "unfreezes a frozen account through a CSRF-protected POST", %{conn: conn} do
      user =
        insert(:activated_user,
          username: "thawme",
          frozen_at: NaiveDateTime.utc_now(:second)
        )

      conn = get(conn, ~p"/admin/accounts/frozen")
      assert html_response(conn, 200) =~ ~s(action="/admin/accounts/#{user.id}/unfreeze")

      conn =
        submit_with_csrf(conn, ~p"/admin/accounts/#{user.id}/unfreeze", %{
          "return_to" => "/admin/accounts/frozen"
        })

      assert redirected_to(conn) == "/admin/accounts/frozen"
      refute Repo.get!(User, user.id).frozen_at
      assert [%AdminAction{action: "account_unfrozen"}] = frozen_actions(user.id)
    end

    test "freezing an unknown account flashes an error instead of 500ing", %{conn: conn} do
      # A search result renders a freeze form, which carries the CSRF token.
      insert(:activated_user, username: "tokenholder1")
      conn = get(conn, ~p"/admin/accounts?q=tokenholder1")

      conn =
        submit_with_csrf(conn, ~p"/admin/accounts/#{Vutuv.UUIDv7.generate()}/freeze", %{
          "return_to" => "/admin/accounts"
        })

      assert redirected_to(conn) == "/admin/accounts"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer exists"
    end

    test "a malformed account id does not raise", %{conn: conn} do
      insert(:activated_user, username: "tokenholder2")
      conn = get(conn, ~p"/admin/accounts?q=tokenholder2")

      conn =
        submit_with_csrf(conn, ~p"/admin/accounts/not-a-uuid/freeze", %{
          "return_to" => "/admin/accounts"
        })

      assert redirected_to(conn) == "/admin/accounts"
    end

    test "an off-site return_to falls back to the frozen list (no open redirect)", %{conn: conn} do
      user = insert(:activated_user, username: "redirectme")
      conn = get(conn, ~p"/admin/accounts?q=redirectme")

      conn =
        submit_with_csrf(conn, ~p"/admin/accounts/#{user.id}/freeze", %{
          "return_to" => "https://evil.example/phish"
        })

      assert redirected_to(conn) == ~p"/admin/accounts/frozen"
    end
  end

  describe "frozen list" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      %{conn: conn, admin: admin}
    end

    test "lists currently frozen accounts with an Unfreeze control", %{conn: conn} do
      insert(:activated_user,
        username: "inthefreezer",
        frozen_at: NaiveDateTime.utc_now(:second)
      )

      response = html_response(get(conn, ~p"/admin/accounts/frozen"), 200)
      assert response =~ "@inthefreezer"
      assert response =~ "Unfreeze"
    end

    test "labels the source of a report-driven freeze", %{conn: conn} do
      reported =
        insert(:activated_user,
          username: "reportedfreeze",
          frozen_at: NaiveDateTime.utc_now(:second)
        )

      Repo.insert!(%Case{
        content_type: "user",
        content_id: reported.id,
        owner_id: reported.id,
        status: "escalated"
      })

      response = html_response(get(conn, ~p"/admin/accounts/frozen"), 200)
      assert response =~ "report"
    end
  end
end
