defmodule VutuvWeb.MastodonApi.ProfileControllerTest do
  @moduledoc "Editing your own account from a client, and reporting somebody else's."
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.ApiAuth
  alias Vutuv.Moderation
  alias Vutuv.Posts
  alias Vutuv.Repo

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

  # vutuv keeps a first and a last name; Mastodon sends one string.
  test "display_name is split on the last space and note becomes the headline", %{conn: conn} do
    user = insert(:activated_user)
    token = token_for(user, ["write"])

    account =
      conn
      |> api(token)
      |> patch("/api/v1/accounts/update_credentials", %{
        "display_name" => "Anna Maria Meier",
        "note" => "Baut Brücken"
      })
      |> json_response(200)

    assert account["display_name"] =~ "Anna Maria"

    updated = Repo.reload!(user)
    assert updated.first_name == "Anna Maria"
    assert updated.last_name == "Meier"
    assert updated.headline == "Baut Brücken"
  end

  test "reporting a status opens the same case the website would", %{conn: conn} do
    reporter = insert(:activated_user)
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Zu melden"})

    token = token_for(reporter, ["write"])

    assert conn
           |> api(token)
           |> post("/api/v1/reports", %{
             "account_id" => author.id,
             "status_ids" => [post.id],
             "category" => "spam",
             "comment" => "Unerwünscht"
           })
           |> json_response(200)

    assert Moderation.open_case_for(post)
  end

  test "your own content cannot be reported", %{conn: conn} do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Meins"})
    token = token_for(author, ["write"])

    assert conn
           |> api(token)
           |> post("/api/v1/reports", %{"account_id" => author.id, "status_ids" => [post.id]})
           |> response(422)
  end

  test "an unknown target is a 404", %{conn: conn} do
    token = token_for(insert(:activated_user), ["write"])

    assert conn
           |> api(token)
           |> post("/api/v1/reports", %{"account_id" => Ecto.UUID.generate()})
           |> response(404)
  end
end
