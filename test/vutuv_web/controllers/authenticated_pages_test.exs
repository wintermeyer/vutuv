defmodule VutuvWeb.AuthenticatedPagesTest do
  @moduledoc """
  Smoke tests that log in and GET the main authenticated pages (index, show,
  new, edit) with realistic data. They guard against query and template bugs
  that surface only when authenticated: a controller error raises and fails the
  GET below. `renders/2` asserts a page rendered (2xx/3xx).
  """
  use VutuvWeb.ConnCase

  defp renders(conn, path) do
    conn = get(conn, path)
    assert conn.status in 200..399, "GET #{path} returned HTTP #{conn.status}"
    conn
  end

  describe "authenticated user pages" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      tag = insert(:tag)

      endorse = fn u ->
        ut = insert(:user_tag, user: u, tag: tag)
        insert(:user_tag_endorsement, user_tag: ut, user: insert(:user))
      end

      endorse.(user)

      follower = insert(:user)
      followee = insert(:user)
      insert(:follow, follower: follower, followee: user)
      insert(:follow, follower: user, followee: followee)
      endorse.(follower)
      endorse.(followee)

      email = insert(:email, user: user)
      work = insert(:work_experience, user: user)
      url = insert(:url, user: user)
      phone = insert(:phone_number, user: user)
      address = insert(:address, user: user)
      social = insert(:social_media_account, user: user)
      insert(:search_term, user: user)

      %{
        conn: conn,
        user: user,
        tag: tag,
        email: email,
        work: work,
        url: url,
        phone: phone,
        address: address,
        social: social
      }
    end

    test "profile + tag pages render", %{conn: conn, user: user, tag: tag} do
      renders(conn, ~p"/#{user}")
      renders(conn, ~p"/#{user}/tags")
      renders(conn, ~p"/#{user}/tags/#{tag}")
      renders(conn, ~p"/#{user}/followers")
      renders(conn, ~p"/#{user}/following")
    end

    test "profile sub-resource index pages render", %{conn: conn, user: user} do
      renders(conn, ~p"/#{user}/emails")
      renders(conn, ~p"/#{user}/phone_numbers")
      renders(conn, ~p"/#{user}/links")
      renders(conn, ~p"/#{user}/social_media_accounts")
      renders(conn, ~p"/#{user}/work_experiences")
      renders(conn, ~p"/#{user}/addresses")
    end

    test "new forms render", %{conn: conn, user: _user} do
      renders(conn, ~p"/settings/profile")
      renders(conn, ~p"/settings/emails/new")
      renders(conn, ~p"/settings/phone_numbers/new")
      renders(conn, ~p"/settings/links/new")
      renders(conn, ~p"/settings/social_media_accounts/new")
      renders(conn, ~p"/settings/work_experiences/new")
      renders(conn, ~p"/settings/addresses/new")
    end

    test "show/edit for sub-resources render", %{
      conn: conn,
      user: _user,
      email: email,
      phone: phone,
      url: url,
      address: address,
      social: social
    } do
      renders(conn, ~p"/settings/emails/#{email}/edit")
      renders(conn, ~p"/settings/phone_numbers/#{phone}/edit")
      renders(conn, ~p"/settings/links/#{url}/edit")
      renders(conn, ~p"/settings/addresses/#{address}/edit")
      renders(conn, ~p"/settings/social_media_accounts/#{social}/edit")
    end

    test "public listing and global tag pages render", %{conn: conn, tag: tag} do
      renders(conn, ~p"/listings/most_followed_users")
      renders(conn, ~p"/tags")
      renders(conn, ~p"/tags/#{tag}")
    end
  end

  describe "admin pages" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      # An unverified user with no last name (the case that crashed the
      # dashboard) plus a tag for the listing.
      insert(:user, last_name: nil)
      insert(:tag)
      %{conn: conn, admin: admin}
    end

    test "admin pages render", %{conn: conn} do
      renders(conn, ~p"/admin")
      renders(conn, ~p"/admin/users")
      renders(conn, ~p"/admin/tags")
      renders(conn, ~p"/admin/usernames")
    end

    test "the member browser lists newest registrations first", %{conn: conn} do
      older = insert(:user, first_name: "Older", identity_verified?: false)
      insert(:user, first_name: "Newer", identity_verified?: false)

      Repo.update_all(
        from(u in Vutuv.Accounts.User, where: u.id == ^older.id),
        set: [inserted_at: ~N[2020-01-01 12:00:00]]
      )

      body = conn |> get(~p"/admin/users?reg=all") |> html_response(200)

      {newer_pos, _} = :binary.match(body, "Newer")
      {older_pos, _} = :binary.match(body, "Older")
      assert newer_pos < older_pos
    end

    test "the member browser survives garbage page params", %{conn: conn} do
      insert(:user, first_name: "Pending", identity_verified?: false)

      assert conn |> get(~p"/admin/users?reg=all&page=banana") |> html_response(200) =~ "Pending"
      assert conn |> get(~p"/admin/users?reg=all&page=999") |> html_response(200) =~ "Pending"
    end
  end

  describe "authenticated write actions" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, other: insert(:user), phone: insert(:phone_number, user: user)}
    end

    test "create a phone number", %{conn: conn, user: _user} do
      conn =
        post(conn, ~p"/settings/phone_numbers",
          phone_number: %{value: "+49 30 5550000", number_type: "Cell"}
        )

      assert conn.status < 500, "phone create -> #{conn.status}"
    end

    test "create a link", %{conn: conn, user: _user} do
      conn =
        post(conn, ~p"/settings/links",
          url: %{value: "https://example.org/", description: "Site"}
        )

      assert conn.status < 500, "link create -> #{conn.status}"
    end

    test "update a phone number", %{conn: conn, user: _user, phone: phone} do
      conn =
        put(conn, ~p"/settings/phone_numbers/#{phone}", phone_number: %{value: "+49 30 5551111"})

      assert conn.status < 500, "phone update -> #{conn.status}"
    end

    test "delete a phone number", %{conn: conn, user: _user, phone: phone} do
      conn = delete(conn, ~p"/settings/phone_numbers/#{phone}")
      assert conn.status < 500, "phone delete -> #{conn.status}"
    end

    test "follow another user", %{conn: conn, other: other} do
      conn = post(conn, ~p"/follows", follow: %{followee_id: other.id})
      assert conn.status < 500, "follow -> #{conn.status}"
    end
  end

  describe "admin write flows" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      target = insert(:user)
      insert(:email, user: target)

      %{
        conn: conn,
        admin: admin,
        target: target,
        tag: insert(:tag)
      }
    end

    test "admin new/edit forms render", %{conn: conn, tag: tag} do
      renders(conn, ~p"/admin/tags/new")
      renders(conn, ~p"/admin/tags/#{tag}/edit")
    end

    test "admin create tag", %{conn: conn} do
      # A tag name is a single token (no spaces), so keep the smoke-test name
      # space-free or the create fails validation instead of exercising it.
      assert post(conn, ~p"/admin/tags", tag: %{name: "AdminTag"}).status < 500
    end

    test "admin update / delete tag", %{conn: conn, tag: tag} do
      assert put(conn, ~p"/admin/tags/#{tag}", tag: %{name: "Renamed"}).status < 500
      assert delete(conn, ~p"/admin/tags/#{tag}").status < 500
    end

    test "admin verify user and disable slug", %{conn: conn, target: target} do
      assert post(conn, ~p"/admin/users", user_id: target.id).status < 500

      assert post(conn, ~p"/admin/usernames", username_disable: %{value: target.username}).status <
               500
    end
  end
end
