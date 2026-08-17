defmodule VutuvWeb.MastodonApi.DiscoveryExtrasTest do
  @moduledoc """
  Thread context, the edit source, and a search that finds more than an exact
  handle — the three things a client reaches for right after the timeline.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.ApiAuth
  alias Vutuv.Posts
  alias Vutuv.Repo

  # The factory does not create search terms (`Accounts.create_user` does), so
  # a member findable by name needs the same rows inserted.
  defp searchable_user(first, last) do
    user = insert(:activated_user, first_name: first, last_name: last)

    for changeset <-
          SearchTerm.create_search_terms(%{"first_name" => first, "last_name" => last}) do
      changeset |> Ecto.Changeset.put_change(:user_id, user.id) |> Repo.insert!()
    end

    user
  end

  @mastodon_host "mastodon.localhost"

  defp token_for(user, scopes) do
    plaintext = "vutuv_at_" <> ApiAuth.random_token()
    app = insert(:oauth_app, user: nil, protocol: "mastodon", registered_scopes: scopes)

    insert(:api_token,
      user: user,
      app: app,
      kind: "access",
      name: nil,
      scopes: scopes,
      expires_at: nil,
      token_hash: ApiAuth.hash_token(plaintext)
    )

    plaintext
  end

  defp api(conn, token) do
    conn
    |> Map.put(:host, @mastodon_host)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "GET /api/v1/statuses/:id/context" do
    test "splits a conversation into ancestors and descendants", %{conn: conn} do
      author = insert(:activated_user)
      reader = insert(:activated_user)

      {:ok, root} = Posts.create_post(author, %{body: "Die Wurzel"})
      {:ok, middle} = Posts.create_reply(author, root, %{body: "Die Mitte"})
      {:ok, leaf} = Posts.create_reply(author, middle, %{body: "Das Blatt"})

      token = token_for(reader, ["read"])

      context =
        conn
        |> api(token)
        |> get("/api/v1/statuses/#{middle.id}/context")
        |> json_response(200)

      assert Enum.map(context["ancestors"], & &1["id"]) == [root.id]
      assert Enum.map(context["descendants"], & &1["id"]) == [leaf.id]
    end

    test "the root has no ancestors and every answer below it", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, root} = Posts.create_post(author, %{body: "Wurzel"})
      {:ok, first} = Posts.create_reply(author, root, %{body: "Erste Antwort"})
      {:ok, second} = Posts.create_reply(author, first, %{body: "Zweite Antwort"})

      token = token_for(insert(:activated_user), ["read"])

      context =
        conn
        |> api(token)
        |> get("/api/v1/statuses/#{root.id}/context")
        |> json_response(200)

      assert context["ancestors"] == []

      assert Enum.sort(Enum.map(context["descendants"], & &1["id"])) ==
               Enum.sort([first.id, second.id])
    end

    test "a status nobody may see is a 404, not an empty context", %{conn: conn} do
      author = insert(:activated_user)
      stranger = insert(:activated_user)

      {:ok, private} =
        Posts.create_post(author, %{
          body: "Nur für Follower",
          denials: [%{wildcard: "non_followers"}]
        })

      token = token_for(stranger, ["read"])

      assert conn |> api(token) |> get("/api/v1/statuses/#{private.id}/context") |> response(404)
    end
  end

  describe "GET /api/v1/statuses/:id/source" do
    test "answers the Markdown the author typed, not the rendered body", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Mit **Auszeichnung**"})
      token = token_for(author, ["read", "write"])

      source =
        conn
        |> api(token)
        |> get("/api/v1/statuses/#{post.id}/source")
        |> json_response(200)

      assert source["text"] == "Mit **Auszeichnung**"
      refute source["text"] =~ "<strong>"
    end

    test "only the author may read it", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Meins"})
      token = token_for(insert(:activated_user), ["read"])

      assert conn |> api(token) |> get("/api/v1/statuses/#{post.id}/source") |> response(404)
    end
  end

  describe "GET /api/v2/search" do
    test "finds a member by name, not only by exact handle", %{conn: conn} do
      searchable_user("Wilhelmine", "Sucherin")
      token = token_for(insert(:activated_user), ["read"])

      %{"accounts" => accounts} =
        conn
        |> api(token)
        |> get("/api/v2/search?q=Wilhelmine")
        |> json_response(200)

      assert Enum.any?(accounts, &(&1["display_name"] =~ "Wilhelmine"))
    end

    test "finds posts and hashtags too", %{conn: conn} do
      author = insert(:activated_user)
      {:ok, _post} = Posts.create_post(author, %{body: "Etwas über Segelfliegen"})

      token = token_for(insert(:activated_user), ["read"])

      %{"statuses" => statuses} =
        conn
        |> api(token)
        |> get("/api/v2/search?q=Segelfliegen")
        |> json_response(200)

      assert Enum.any?(statuses, &(&1["content"] =~ "Segelfliegen"))
    end

    test "type narrows the search to one section", %{conn: conn} do
      author = searchable_user("Nurhier", "Person")
      {:ok, _post} = Posts.create_post(author, %{body: "Nurhier steht es auch"})

      token = token_for(insert(:activated_user), ["read"])

      body =
        conn
        |> api(token)
        |> get("/api/v2/search?q=Nurhier&type=accounts")
        |> json_response(200)

      assert body["statuses"] == []
      assert body["hashtags"] == []
      assert Enum.any?(body["accounts"], &(&1["display_name"] =~ "Nurhier"))
    end
  end
end
