defmodule VutuvWeb.ApiV2.ProfileApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth

  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    user = insert_activated_user()

    {:ok, write_token, _} =
      ApiAuth.create_pat(user, %{"name" => "rw", "scopes" => ["profile:write"]})

    {:ok, read_token, _} =
      ApiAuth.create_pat(user, %{"name" => "ro", "scopes" => ["profile:read"]})

    {:ok, conn: conn, user: user, write_token: write_token, read_token: read_token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json_patch(conn, token, path, body) do
    conn
    |> authed(token)
    |> put_req_header("content-type", "application/json")
    |> patch(path, Jason.encode!(body))
  end

  defp json_post(conn, token, path, body) do
    conn
    |> authed(token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  describe "PATCH /api/2.0/me" do
    test "updates the whitelisted profile fields", %{conn: conn, write_token: token} do
      conn = json_patch(conn, token, "/api/2.0/me", %{headline: "New **headline**"})

      assert json_response(conn, 200)["headline_markdown"] == "New **headline**"
    end

    test "ignores fields outside the API contract", %{conn: conn, user: user, write_token: token} do
      conn =
        json_patch(conn, token, "/api/2.0/me", %{
          first_name: "Renamed",
          active_slug: "stolen_handle",
          activated?: false
        })

      body = json_response(conn, 200)
      assert body["first_name"] == "Renamed"
      assert body["slug"] == user.active_slug

      reloaded = Repo.get!(Vutuv.Accounts.User, user.id)
      assert reloaded.active_slug == user.active_slug
      assert reloaded.activated?
    end

    test "invalid values are a 422 with field errors", %{conn: conn, write_token: token} do
      conn = json_patch(conn, token, "/api/2.0/me", %{birthdate: "not-a-date"})

      assert conn.status == 422
      assert %{"errors" => %{"birthdate" => [_message]}} = Jason.decode!(conn.resp_body)
    end

    test "a read-only token cannot write", %{conn: conn, read_token: token} do
      conn = json_patch(conn, token, "/api/2.0/me", %{headline: "nope"})
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["required_scope"] == "profile:write"
    end
  end

  describe "GET /api/2.0/users/:slug/<section>" do
    test "lists section entries with ids", %{conn: conn, read_token: token} do
      other = insert_activated_user()
      work = insert(:work_experience, user: other)

      conn = get(authed(conn, token), "/api/2.0/users/#{other.active_slug}/work_experiences")
      body = json_response(conn, 200)

      assert body["total"] == 1
      assert [entry] = body["entries"]
      assert entry["id"] == work.id
      assert entry["title"] == work.title
    end

    test "the email list reads through the viewer's eyes", %{
      conn: conn,
      user: user,
      read_token: token
    } do
      other = insert_activated_user()
      insert(:email, user: other, public?: true, value: "public@example.com")
      insert(:email, user: other, public?: false, value: "private@example.com")
      insert(:email, user: user, public?: false, value: "mine-private@example.com")

      conn1 = get(authed(conn, token), "/api/2.0/users/#{other.active_slug}/emails")
      assert json_response(conn1, 200)["entries"] == ["public@example.com"]

      conn2 = get(authed(build_conn(), token), "/api/2.0/users/#{user.active_slug}/emails")
      assert "mine-private@example.com" in json_response(conn2, 200)["entries"]
    end

    test "unknown slugs 404", %{conn: conn, read_token: token} do
      conn = get(authed(conn, token), "/api/2.0/users/nobody/links")
      assert conn.status == 404
    end
  end

  describe "section CRUD on /api/2.0/me" do
    test "create, update, delete a work experience", %{conn: conn, write_token: token} do
      conn1 =
        json_post(conn, token, "/api/2.0/me/work_experiences", %{
          title: "Developer",
          organization: "ACME",
          start_year: 2024,
          start_month: 3
        })

      assert %{"entry" => %{"id" => id, "title" => "Developer", "start" => "2024-03"}} =
               json_response(conn1, 201)

      conn2 =
        json_patch(build_conn(), token, "/api/2.0/me/work_experiences/#{id}", %{
          title: "Senior Developer"
        })

      assert json_response(conn2, 200)["entry"]["title"] == "Senior Developer"

      conn3 = delete(authed(build_conn(), token), "/api/2.0/me/work_experiences/#{id}")
      assert conn3.status == 204
      assert Repo.get(Vutuv.Profiles.WorkExperience, id) == nil
    end

    test "validation errors are a 422 with field errors", %{conn: conn, write_token: token} do
      conn = json_post(conn, token, "/api/2.0/me/work_experiences", %{title: "No org"})

      assert conn.status == 422
      assert %{"errors" => %{"organization" => [_message]}} = Jason.decode!(conn.resp_body)
    end

    test "creates a link and a phone number", %{conn: conn, user: user, write_token: token} do
      conn1 =
        json_post(conn, token, "/api/2.0/me/links", %{
          value: "https://example.org/blog",
          description: "Blog"
        })

      assert %{"entry" => %{"url" => "https://example.org/blog"}} = json_response(conn1, 201)

      conn2 =
        json_post(build_conn(), token, "/api/2.0/me/phone_numbers", %{
          value: "+49 261 1234567",
          number_type: "work"
        })

      assert %{"entry" => %{"value" => "+49 261 1234567", "type" => "work"}} =
               json_response(conn2, 201)

      assert length(Repo.all(Ecto.assoc(user, :urls))) == 1
      assert length(Repo.all(Ecto.assoc(user, :phone_numbers))) == 1
    end

    test "cannot touch someone else's entries", %{conn: conn, write_token: token} do
      other = insert_activated_user()
      work = insert(:work_experience, user: other)

      conn1 = json_patch(conn, token, "/api/2.0/me/work_experiences/#{work.id}", %{title: "x"})
      assert conn1.status == 404

      conn2 = delete(authed(build_conn(), token), "/api/2.0/me/work_experiences/#{work.id}")
      assert conn2.status == 404
      assert Repo.get(Vutuv.Profiles.WorkExperience, work.id)
    end
  end

  describe "tags" do
    test "add, list and remove a tag", %{conn: conn, user: user, write_token: token} do
      conn1 = json_post(conn, token, "/api/2.0/me/tags", %{name: "Phoenix"})
      assert %{"entry" => %{"id" => id, "name" => "Phoenix"}} = json_response(conn1, 201)

      conn2 = get(authed(build_conn(), token), "/api/2.0/users/#{user.active_slug}/tags")
      assert [%{"name" => "Phoenix"}] = json_response(conn2, 200)["entries"]

      conn3 = delete(authed(build_conn(), token), "/api/2.0/me/tags/#{id}")
      assert conn3.status == 204

      assert json_response(
               get(authed(build_conn(), token), "/api/2.0/users/#{user.active_slug}/tags"),
               200
             )["entries"] == []
    end

    test "a missing name is a 400", %{conn: conn, write_token: token} do
      conn = json_post(conn, token, "/api/2.0/me/tags", %{})
      assert conn.status == 400
    end
  end
end
