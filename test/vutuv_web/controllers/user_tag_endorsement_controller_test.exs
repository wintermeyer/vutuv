defmodule VutuvWeb.UserTagEndorsementControllerTest do
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Tags.UserTagEndorsement

  # This controller runs two guard plugs before every action:
  #
  #   * `resolve_slug` loads the user-tag id scoped to the *path user's* tags
  #     (an unknown / foreign slug 404s and halts), and
  #   * `require_user_logged_in` 404s (it deliberately does NOT redirect like the
  #     RequireLogin plug) when there is no session user.
  #
  # Both are copied verbatim across sibling controllers, so they get pulled into
  # shared plugs. These tests pin the externally observable behavior.

  defp validated_user_with_slug do
    user = insert(:user, validated?: true)
    insert(:slug, value: user.active_slug, disabled: false, user: user)
    user
  end

  describe "resolve_slug on an unknown user-tag slug" do
    test "create returns a clean 404 and stores nothing", %{conn: conn} do
      user = validated_user_with_slug()

      conn =
        post(conn, ~p"/users/#{user}/user_tag_endorsements", id: "does-not-exist")

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end

  describe "owner-scoping of the user-tag slug" do
    test "a tag belonging to another user does not resolve under this user", %{conn: conn} do
      user = validated_user_with_slug()
      other = validated_user_with_slug()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      insert(:user_tag, user: other, tag: tag)

      conn =
        post(conn, ~p"/users/#{user}/user_tag_endorsements", id: tag.slug)

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end

  describe "require_user_logged_in" do
    test "create on a resolvable tag 404s when logged out (does not redirect)", %{conn: conn} do
      user = validated_user_with_slug()
      tag = insert(:tag, name: "Elixir", slug: "elixir")
      insert(:user_tag, user: user, tag: tag)

      conn =
        post(conn, ~p"/users/#{user}/user_tag_endorsements", id: tag.slug)

      assert conn.status == 404
      assert conn.halted
      assert Repo.aggregate(UserTagEndorsement, :count) == 0
    end
  end
end
