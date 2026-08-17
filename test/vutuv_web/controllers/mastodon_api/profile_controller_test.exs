defmodule VutuvWeb.MastodonApi.ProfileControllerTest do
  @moduledoc "Editing your own account from a client, and reporting somebody else's."
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Moderation
  alias Vutuv.Posts
  alias Vutuv.Repo

  # vutuv keeps a first and a last name; Mastodon sends one string.
  test "display_name is split on the last space and note becomes the headline", %{conn: conn} do
    user = insert(:activated_user)
    token = mastodon_token(user, ["write"])

    account =
      conn
      |> mastodon_conn(token)
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

    token = mastodon_token(reporter, ["write"])

    assert conn
           |> mastodon_conn(token)
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
    token = mastodon_token(author, ["write"])

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/reports", %{"account_id" => author.id, "status_ids" => [post.id]})
           |> response(422)
  end

  test "an unknown target is a 404", %{conn: conn} do
    token = mastodon_token(insert(:activated_user), ["write"])

    assert conn
           |> mastodon_conn(token)
           |> post("/api/v1/reports", %{"account_id" => Ecto.UUID.generate()})
           |> response(404)
  end
end
