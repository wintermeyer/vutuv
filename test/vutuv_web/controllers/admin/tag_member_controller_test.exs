defmodule VutuvWeb.Admin.TagMemberControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Repo
  alias Vutuv.Tags.UserTag

  # The member roster behind an honor tag ("vutuv_developer"): only
  # admins may add or remove members, and assignment accepts either a @handle or
  # an email address.

  defp holds_tag?(user, tag) do
    Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id and ut.tag_id == ^tag.id))
  end

  describe "as an admin" do
    setup %{conn: conn} do
      {conn, admin} = create_and_login_admin(conn)
      name = unique_tag_name("vutuv_developer")
      tag = insert(:tag, name: name, slug: name, honor?: true)
      {:ok, conn: conn, admin: admin, tag: tag}
    end

    test "the tag show page renders the add-member form action", %{conn: conn, tag: tag} do
      html = conn |> get(~p"/admin/tags/#{tag}") |> html_response(200)
      # Exercise the rendered action, not just the route we know exists.
      assert html =~ ~s(action="/admin/tags/#{tag.slug}/members")
    end

    test "adds a member by @handle", %{conn: conn, tag: tag} do
      member = insert(:user)

      conn = post(conn, ~p"/admin/tags/#{tag}/members", %{"member" => "@" <> member.username})

      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      assert holds_tag?(member, tag)
    end

    test "adds a member by email address", %{conn: conn, tag: tag} do
      member = insert(:user)
      insert(:email, user: member, value: "dev@example.com")

      conn = post(conn, ~p"/admin/tags/#{tag}/members", %{"member" => "dev@example.com"})

      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      assert holds_tag?(member, tag)
    end

    test "adding a member who already holds the tag is a graceful no-op", %{conn: conn, tag: tag} do
      member = insert(:user)
      insert(:user_tag, user: member, tag: tag)

      conn = post(conn, ~p"/admin/tags/#{tag}/members", %{"member" => "@" <> member.username})

      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      # Still exactly one row: no duplicate, no 500.
      assert Repo.aggregate(from(ut in UserTag, where: ut.tag_id == ^tag.id), :count) == 1
    end

    test "reports when no member matches the identifier", %{conn: conn, tag: tag} do
      conn = post(conn, ~p"/admin/tags/#{tag}/members", %{"member" => "@nobody-here"})
      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
    end

    test "removes a member from the tag", %{conn: conn, tag: tag} do
      member = insert(:user)
      insert(:user_tag, user: member, tag: tag)

      conn = delete(conn, ~p"/admin/tags/#{tag}/members/#{member.id}")

      assert redirected_to(conn) == ~p"/admin/tags/#{tag}"
      refute holds_tag?(member, tag)
    end
  end

  describe "as a non-admin" do
    test "cannot add a member (403)", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      tag = insert(:tag, honor?: true)
      member = insert(:user)

      conn = post(conn, ~p"/admin/tags/#{tag}/members", %{"member" => "@" <> member.username})

      assert conn.status == 403
      refute holds_tag?(member, tag)
    end
  end
end
