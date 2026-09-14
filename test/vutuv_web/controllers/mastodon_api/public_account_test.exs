defmodule VutuvWeb.MastodonApi.PublicAccountTest do
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts

  test "anonymous clients can read a public account and its posts", %{conn: conn} do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Public for FediWings"})

    account =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/accounts/lookup", %{"acct" => author.username})
      |> json_response(200)

    assert account["id"] == author.id

    statuses =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/accounts/#{author.id}/statuses")
      |> json_response(200)

    assert Enum.any?(statuses, &(&1["id"] == post.id))

    status =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/statuses/#{post.id}")
      |> json_response(200)

    assert status["id"] == post.id

    context =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/statuses/#{post.id}/context")
      |> json_response(200)

    assert context["ancestors"] == []

    boosters =
      conn
      |> on_mastodon_host()
      |> get("/api/v1/statuses/#{post.id}/reblogged_by")
      |> json_response(200)

    assert boosters == []
  end

  test "anonymous access remains limited to public reads", %{conn: conn} do
    assert conn
           |> on_mastodon_host()
           |> get("/api/v1/accounts/verify_credentials")
           |> json_response(401) == %{"error" => "The access token is invalid"}

    assert conn
           |> on_mastodon_host()
           |> Plug.Conn.put_req_header("authorization", "Bearer invalid")
           |> get("/api/v1/accounts/lookup", %{"acct" => "anyone"})
           |> json_response(401) == %{"error" => "The access token is invalid"}
  end
end
