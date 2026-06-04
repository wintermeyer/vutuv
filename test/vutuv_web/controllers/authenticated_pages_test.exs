defmodule VutuvWeb.AuthenticatedPagesTest do
  @moduledoc """
  Smoke tests that log in and GET the main authenticated pages (index, show,
  new, edit) with realistic data. They guard against query and template bugs
  that surface only when authenticated: a controller error raises and fails the
  GET below. `renders/2` asserts a page rendered (2xx/3xx); `no_server_error/2`
  only asserts the page did not 5xx, for auth-gated pages that legitimately
  redirect or 403.
  """
  use VutuvWeb.ConnCase

  defp renders(conn, path) do
    conn = get(conn, path)
    assert conn.status in 200..399, "GET #{path} returned HTTP #{conn.status}"
    conn
  end

  defp no_server_error(conn, path) do
    conn = get(conn, path)
    assert conn.status < 500, "GET #{path} returned HTTP #{conn.status}"
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
      insert(:connection, follower: follower, followee: user)
      insert(:connection, follower: user, followee: followee)
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
      renders(conn, ~p"/users/#{user}")
      renders(conn, ~p"/users/#{user}/tags")
      renders(conn, ~p"/users/#{user}/tags/#{tag}")
      renders(conn, ~p"/users/#{user}/followers")
      renders(conn, ~p"/users/#{user}/followees")
    end

    test "profile sub-resource index pages render", %{conn: conn, user: user} do
      renders(conn, ~p"/users/#{user}/emails")
      renders(conn, ~p"/users/#{user}/phone_numbers")
      renders(conn, ~p"/users/#{user}/links")
      renders(conn, ~p"/users/#{user}/social_media_accounts")
      renders(conn, ~p"/users/#{user}/work_experiences")
      renders(conn, ~p"/users/#{user}/addresses")
      renders(conn, ~p"/users/#{user}/search_terms")
    end

    test "new forms render", %{conn: conn, user: user} do
      renders(conn, ~p"/users/#{user}/edit")
      renders(conn, ~p"/users/#{user}/emails/new")
      renders(conn, ~p"/users/#{user}/phone_numbers/new")
      renders(conn, ~p"/users/#{user}/links/new")
      renders(conn, ~p"/users/#{user}/social_media_accounts/new")
      renders(conn, ~p"/users/#{user}/work_experiences/new")
      renders(conn, ~p"/users/#{user}/addresses/new")
    end

    test "show/edit for sub-resources render", %{
      conn: conn,
      user: user,
      email: email,
      phone: phone,
      url: url,
      address: address,
      social: social
    } do
      renders(conn, ~p"/users/#{user}/emails/#{email}/edit")
      renders(conn, ~p"/users/#{user}/phone_numbers/#{phone}/edit")
      renders(conn, ~p"/users/#{user}/links/#{url}/edit")
      renders(conn, ~p"/users/#{user}/addresses/#{address}/edit")
      renders(conn, ~p"/users/#{user}/social_media_accounts/#{social}/edit")
    end

    test "auth-gated pages do not 5xx", %{conn: conn, user: user} do
      no_server_error(conn, ~p"/users/#{user}/groups")
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
      # dashboard) plus a tag and exonym source row for the listings.
      insert(:user, last_name: nil)
      insert(:tag)
      %{conn: conn, admin: admin}
    end

    test "admin pages render", %{conn: conn} do
      renders(conn, ~p"/admin")
      renders(conn, ~p"/admin/locales")
      renders(conn, ~p"/admin/exonyms")
      renders(conn, ~p"/admin/tags")
    end

    test "the verification queue lists newest registrations first", %{conn: conn} do
      older = insert(:user, first_name: "Older", verified: false)
      insert(:user, first_name: "Newer", verified: false)

      Repo.update_all(
        from(u in Vutuv.Accounts.User, where: u.id == ^older.id),
        set: [inserted_at: ~N[2020-01-01 12:00:00]]
      )

      body = conn |> get(~p"/admin") |> html_response(200)

      {newer_pos, _} = :binary.match(body, "Newer")
      {older_pos, _} = :binary.match(body, "Older")
      assert newer_pos < older_pos
    end

    test "the verification queue survives garbage page params", %{conn: conn} do
      insert(:user, first_name: "Pending", verified: false)

      assert conn |> get(~p"/admin?page=banana") |> html_response(200) =~ "Pending"
      assert conn |> get(~p"/admin?page=999") |> html_response(200) =~ "Pending"
    end
  end

  describe "authenticated write actions" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, other: insert(:user), phone: insert(:phone_number, user: user)}
    end

    test "create a phone number", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/#{user}/phone_numbers",
          phone_number: %{value: "+49 30 5550000", number_type: "mobile"}
        )

      assert conn.status < 500, "phone create -> #{conn.status}"
    end

    test "create a link", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/#{user}/links",
          url: %{value: "https://example.org/", description: "Site"}
        )

      assert conn.status < 500, "link create -> #{conn.status}"
    end

    test "update a phone number", %{conn: conn, user: user, phone: phone} do
      conn =
        put(conn, ~p"/users/#{user}/phone_numbers/#{phone}",
          phone_number: %{value: "+49 30 5551111"}
        )

      assert conn.status < 500, "phone update -> #{conn.status}"
    end

    test "delete a phone number", %{conn: conn, user: user, phone: phone} do
      conn = delete(conn, ~p"/users/#{user}/phone_numbers/#{phone}")
      assert conn.status < 500, "phone delete -> #{conn.status}"
    end

    test "follow another user", %{conn: conn, other: other} do
      conn = post(conn, ~p"/connections", connection: %{followee_id: other.id})
      assert conn.status < 500, "follow -> #{conn.status}"
    end
  end

  describe "admin write flows" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      target = insert(:user)
      insert(:email, user: target)
      [locale_a, locale_b | _] = Repo.all(from(l in Vutuv.Accounts.Locale, limit: 2))

      exonym =
        Repo.insert!(%Vutuv.Accounts.Exonym{
          value: "Beispiel",
          locale_id: locale_a.id,
          exonym_locale_id: locale_b.id
        })

      %{
        conn: conn,
        admin: admin,
        target: target,
        slug: insert(:slug, user: target),
        tag: insert(:tag),
        exonym: exonym,
        locale_a: locale_a,
        locale_b: locale_b
      }
    end

    test "admin new/edit forms render", %{
      conn: conn,
      tag: tag,
      exonym: exonym
    } do
      renders(conn, ~p"/admin/tags/new")
      renders(conn, ~p"/admin/tags/#{tag}/edit")
      renders(conn, ~p"/admin/exonyms/new")
      renders(conn, ~p"/admin/exonyms/#{exonym}/edit")
    end

    test "admin create tag / exonym", %{
      conn: conn,
      locale_a: locale_a,
      locale_b: locale_b
    } do
      assert post(conn, ~p"/admin/tags", tag: %{name: "Admin Tag"}).status < 500

      assert post(conn, ~p"/admin/exonyms",
               exonym: %{value: "Exonym", locale_id: locale_a.id, exonym_locale_id: locale_b.id}
             ).status < 500
    end

    test "admin update / delete tag", %{conn: conn, tag: tag} do
      assert put(conn, ~p"/admin/tags/#{tag}", tag: %{name: "Renamed"}).status < 500
      assert delete(conn, ~p"/admin/tags/#{tag}").status < 500
    end

    test "admin verify user and disable slug", %{conn: conn, target: target, slug: slug} do
      assert post(conn, ~p"/admin/users", user_id: target.id).status < 500
      assert post(conn, ~p"/admin/slugs", slug_disable: %{value: slug.value}).status < 500
    end
  end
end
