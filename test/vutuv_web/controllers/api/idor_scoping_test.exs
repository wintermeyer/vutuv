defmodule VutuvWeb.Api.IdorScopingTest do
  use VutuvWeb.ConnCase, async: true

  # The read-only API exposes per-user sub-resources under
  # `/api/1.0/users/:user_slug/...`. The `show/2` actions used to load the
  # resource by id alone (`Repo.get!(Schema, id)`), ignoring the resolved path
  # user, so resource A's id could be read under user B's path (audit findings
  # #15 and #37). Each `show/2` is now scoped to the path user, mirroring the
  # `index/2` queries (including the email `public?` visibility filter).
  #
  # The two scoping styles 404 differently:
  #   * EmailController.show uses `Repo.one` + a `nil` clause that renders an
  #     explicit 404 JSON, so the conn carries `status == 404`.
  #   * The other show actions use `Repo.get!(assoc(...), id)`, which raises
  #     `Ecto.NoResultsError`. `Plug.Exception` maps that to 404 in production;
  #     in the test env the exception propagates, so we assert via
  #     `assert_error_sent/2`.

  setup do
    owner = insert(:user, active_slug: "owner-slug", validated?: true)
    insert(:slug, value: "owner-slug", disabled: false, user: owner)

    other = insert(:user, active_slug: "other-slug", validated?: true)
    insert(:slug, value: "other-slug", disabled: false, user: other)

    %{owner: owner, other: other}
  end

  describe "GET /api/1.0/users/:user_slug/emails/:id" do
    test "returns the path user's own public email", %{owner: owner} do
      email = insert(:email, user: owner, public?: true)

      conn = get(build_conn(), "/api/1.0/users/owner-slug/emails/#{email.id}")

      assert json_response(conn, 200)
    end

    test "404s when the email belongs to another user", %{other: other} do
      foreign = insert(:email, user: other, public?: true)

      conn = get(build_conn(), "/api/1.0/users/owner-slug/emails/#{foreign.id}")

      assert conn.status == 404
    end

    test "404s when the path user's email is not public", %{owner: owner} do
      private = insert(:email, user: owner, public?: false)

      conn = get(build_conn(), "/api/1.0/users/owner-slug/emails/#{private.id}")

      assert conn.status == 404
    end
  end

  describe "GET /api/1.0/users/:user_slug/addresses/:id" do
    test "returns the path user's own address", %{owner: owner} do
      address = insert(:address, user: owner)

      conn = get(build_conn(), "/api/1.0/users/owner-slug/addresses/#{address.id}")

      assert json_response(conn, 200)
    end

    test "404s when the address belongs to another user", %{other: other} do
      foreign = insert(:address, user: other)

      assert_error_sent(404, fn ->
        get(build_conn(), "/api/1.0/users/owner-slug/addresses/#{foreign.id}")
      end)
    end
  end

  describe "GET /api/1.0/users/:user_slug/groups/:id" do
    test "returns the path user's own group", %{owner: owner} do
      group = insert(:group, user: owner)

      conn = get(build_conn(), "/api/1.0/users/owner-slug/groups/#{group.id}")

      assert json_response(conn, 200)
    end

    test "404s when the group belongs to another user", %{other: other} do
      foreign = insert(:group, user: other)

      assert_error_sent(404, fn ->
        get(build_conn(), "/api/1.0/users/owner-slug/groups/#{foreign.id}")
      end)
    end
  end
end
