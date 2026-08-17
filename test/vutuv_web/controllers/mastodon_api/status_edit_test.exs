defmodule VutuvWeb.MastodonApi.StatusEditTest do
  @moduledoc """
  What an edit from a phone must **not** quietly change.

  `Vutuv.Posts.update_post/2` replaces a post's audience and its tags with
  whatever the attrs carry — `put_assoc/3` on two associations declared
  `on_replace: :delete` — and a Mastodon client speaks neither. Naming only the
  body and the images therefore did not leave them alone, it cleared them: a
  post its author had closed to somebody came back **public**, was federated
  that way by `run_update/3`, and lost its tags on the way. Nothing errored,
  because `check_visibility_lock/2` only refuses *narrowing* an audience.

  Calibrated against the un-fixed controller: drop the
  `Posts.unchanged_audience_attrs/1` merge in `StatusController.update/2` and
  both tests here go red — the first because the post comes back unrestricted,
  the second because its tags are gone.

  `async: false`: it edits through the endpoints the rate limiter counts.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Repo

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp edit(token, post, body) do
    build_conn()
    |> mastodon_conn(token)
    |> put("/api/v1/statuses/#{post.id}", %{"status" => body})
    |> json_response(200)
  end

  test "editing the body keeps the audience the author chose" do
    author = insert(:activated_user)
    token = mastodon_token(author, ["read", "write"])

    {:ok, post} =
      Posts.create_post(author, %{
        body: "Nur für Folgende",
        denials: [%{"wildcard" => "non_followers"}]
      })

    assert Posts.restricted?(post)

    edit(token, post, "Nur für Folgende, jetzt ohne Tippfehler")

    reloaded = post.id |> Posts.get_post() |> Repo.preload(:denials)

    assert Posts.restricted?(reloaded), "the edit published a post its author had closed"
    assert [%{wildcard: "non_followers"}] = reloaded.denials
    assert reloaded.body == "Nur für Folgende, jetzt ohne Tippfehler"
  end

  test "editing the body keeps the tags" do
    author = insert(:activated_user)
    token = mastodon_token(author, ["read", "write"])
    tag_name = Vutuv.Factory.unique_tag_name("elixir")

    {:ok, post} = Posts.create_post(author, %{body: "Mit Thema", tags: [tag_name]})

    assert [_one] = post.id |> Posts.get_post() |> Repo.preload(:tags) |> Map.fetch!(:tags)

    edit(token, post, "Mit Thema, überarbeitet")

    reloaded = post.id |> Posts.get_post() |> Repo.preload(:tags)

    assert [%{name: ^tag_name}] = reloaded.tags
  end
end
