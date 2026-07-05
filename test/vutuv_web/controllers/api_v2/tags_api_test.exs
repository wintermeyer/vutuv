defmodule VutuvWeb.ApiV2.TagsApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Tags
  alias Vutuv.Tags.UserTag

  # The authorized member's own tags over the API. An honor tag is
  # reserved: it can neither be self-created (422) nor self-removed (403).

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    user = insert_activated_user()

    {:ok, write_token, _} =
      ApiAuth.create_pat(user, %{"name" => "rw", "scopes" => ["profile:write"]})

    {:ok, conn: conn, user: user, write_token: write_token}
  end

  describe "POST /api/2.0/me/tags" do
    test "creates a normal tag", %{conn: conn, user: user, write_token: token} do
      conn = json_post(conn, token, "/api/2.0/me/tags", %{"name" => "Elixir"})

      assert conn.status == 201

      assert Repo.exists?(
               from(ut in UserTag,
                 join: t in assoc(ut, :tag),
                 where: ut.user_id == ^user.id and t.slug == "elixir"
               )
             )
    end

    test "refuses a reserved (honor) tag with 422", %{
      conn: conn,
      user: user,
      write_token: token
    } do
      insert(:tag, name: "vutuv_developer", slug: "vutuv_developer", honor?: true)

      conn = json_post(conn, token, "/api/2.0/me/tags", %{"name" => "vutuv_developer"})

      assert conn.status == 422
      refute Repo.exists?(from(ut in UserTag, where: ut.user_id == ^user.id))
    end
  end

  describe "DELETE /api/2.0/me/tags/:id" do
    test "removes a normal tag", %{conn: conn, user: user, write_token: token} do
      {:ok, user_tag} = Tags.add_user_tag(user, "Elixir")

      conn = conn |> authed(token) |> delete("/api/2.0/me/tags/#{user_tag.id}")

      assert conn.status == 204
      refute Repo.get(UserTag, user_tag.id)
    end

    test "refuses to remove an honor tag with 403", %{
      conn: conn,
      user: user,
      write_token: token
    } do
      tag = insert(:tag, name: "vutuv_developer", slug: "vutuv_developer", honor?: true)
      {:ok, user_tag} = Tags.admin_assign_tag(tag, user)

      conn = conn |> authed(token) |> delete("/api/2.0/me/tags/#{user_tag.id}")

      assert conn.status == 403
      assert Repo.get(UserTag, user_tag.id)
    end
  end
end
