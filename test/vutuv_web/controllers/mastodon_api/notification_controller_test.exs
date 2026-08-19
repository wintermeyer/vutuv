defmodule VutuvWeb.MastodonApi.NotificationControllerTest do
  @moduledoc """
  The notifications tab, which answered an empty list until now although vutuv
  has had real notifications all along.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Activity
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias VutuvWeb.RemoteMediaToken

  test "a like and a follow arrive as favourite and follow", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Worauf reagiert wird"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])

    notifications =
      conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

    types = notifications |> Enum.map(& &1["type"]) |> Enum.sort()
    assert types == ["favourite", "follow"]

    favourite = Enum.find(notifications, &(&1["type"] == "favourite"))
    assert favourite["account"]["id"] == liker.id
    assert favourite["status"]["id"] == post.id

    follow = Enum.find(notifications, &(&1["type"] == "follow"))
    assert follow["account"]["id"] == follower.id
    assert follow["status"] == nil
  end

  # vutuv has kinds Mastodon does not — a tag endorsement is the everyday one.
  # Serving it under an invented type is worse than leaving it out, because a
  # client can neither render nor act on a type it does not know.
  test "a kind Mastodon has no type for is left out rather than invented", %{conn: conn} do
    member = insert(:activated_user)
    endorser = insert(:activated_user)
    user_tag = insert(:user_tag, user: member)

    Activity.notify_endorsement(member.id, endorser, Vutuv.Repo.preload(user_tag, :tag).tag)

    token = mastodon_token(member, ["read"])

    notifications =
      conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

    assert notifications == []
  end

  test "types[] and exclude_types[] narrow the list", %{conn: conn} do
    member = insert(:activated_user)
    liker = insert(:activated_user)
    follower = insert(:activated_user)

    {:ok, post} = Posts.create_post(member, %{body: "Beides"})
    :ok = Posts.like_post(liker, post)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])

    only_follows =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?types[]=follow")
      |> json_response(200)

    assert Enum.map(only_follows, & &1["type"]) == ["follow"]

    without_follows =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?exclude_types[]=follow")
      |> json_response(200)

    assert Enum.map(without_follows, & &1["type"]) == ["favourite"]
  end

  test "the unread count and clearing it", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read", "write"])

    assert %{"count" => count} =
             conn
             |> mastodon_conn(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)

    assert count >= 1

    assert build_conn()
           |> mastodon_conn(token)
           |> post("/api/v1/notifications/clear")
           |> json_response(200) == %{}

    assert %{"count" => 0} =
             build_conn()
             |> mastodon_conn(token)
             |> get("/api/v1/notifications/unread_count")
             |> json_response(200)
  end

  test "a single notification can be fetched and an unknown id is a 404", %{conn: conn} do
    member = insert(:activated_user)
    follower = insert(:activated_user)
    {:ok, _} = Social.follow(follower, member.id)

    token = mastodon_token(member, ["read"])
    [one] = conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

    fetched =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/notifications/#{one["id"]}")
      |> json_response(200)

    assert fetched["id"] == one["id"]

    assert build_conn()
           |> mastodon_conn(token)
           |> get("/api/v1/notifications/follower-#{Ecto.UUID.generate()}")
           |> response(404)
  end

  # A client pages by handing back the `id` it was given, and these ids are not
  # bare uuids — they are the derived item's key, `like-<uuid>`. `cast_or_nil/1`
  # answers nil for that, a nil boundary is *no* boundary, and no boundary is
  # the newest page: before the prefix was stripped off the incoming `max_id`,
  # "load more" served page one again, forever. Calibrated against the un-fixed
  # controller, where the second page comes back identical to the first.
  test "paging by the id a client was given advances the list", %{conn: conn} do
    member = insert(:activated_user)
    {:ok, post} = Posts.create_post(member, %{body: "Viel beachtet"})

    for _n <- 1..4, do: :ok = Posts.like_post(insert(:activated_user), post)

    token = mastodon_token(member, ["read"])

    first =
      conn
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?limit=2")
      |> json_response(200)

    assert length(first) == 2

    second =
      build_conn()
      |> mastodon_conn(token)
      |> get("/api/v1/notifications?limit=2&max_id=#{List.last(first)["id"]}")
      |> json_response(200)

    assert length(second) == 2

    assert MapSet.disjoint?(
             MapSet.new(first, & &1["id"]),
             MapSet.new(second, & &1["id"])
           ),
           "the second page repeated the first — the boundary never reached the query"
  end

  # A favourite or boost from another network names an actor with no vutuv
  # profile, so `Vutuv.Activity` carries only their handle and actor URI — but
  # when somebody's reply or reaction was stored, their `RemoteAccount` was
  # too, gate-cleared avatar included. Statuses learned to wear that face in
  # #1588; the notification list hardcoded the installation icon (issue #1598).
  describe "a favourite arriving from another network" do
    test "wears the actor's cached face, not the installation icon", %{conn: conn} do
      member = insert(:activated_user)
      {:ok, post} = Posts.create_post(member, %{body: "Bis ins Fediverse"})

      actor_uri = "https://social.example/users/carol-#{System.unique_integer([:positive])}"

      account =
        Repo.insert!(%RemoteAccount{
          actor_uri: actor_uri,
          host: "social.example",
          handle: "carol",
          name: "Carol",
          inbox_uri: actor_uri <> "/inbox",
          avatar: "avatar-abc123.avif",
          avatar_moderation: "approved"
        })

      remote_reaction(post, actor_uri, "carol")

      token = mastodon_token(member, ["read"])

      [favourite] =
        conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

      assert favourite["type"] == "favourite"
      assert favourite["account"]["id"] == "remote-" <> account.id

      # Plus the capability the picture's proxy wants — a phone app's image
      # loader sends no cookie, so the URL has to carry its own permission.
      assert String.starts_with?(
               favourite["account"]["avatar"],
               MastodonApi.main_url(RemoteAccount.avatar_url(account)) <> "?"
             )

      assert favourite["account"]["avatar"]
             |> avatar_capability()
             |> RemoteMediaToken.avatar?(account.id, account.avatar)

      refute favourite["account"]["avatar"] == Presenter.fallback_avatar()
    end

    test "keeps the stand-in for an actor nobody here stored", %{conn: conn} do
      member = insert(:activated_user)
      {:ok, post} = Posts.create_post(member, %{body: "Auch bis ins Fediverse"})

      actor_uri = "https://social.example/users/nobody-#{System.unique_integer([:positive])}"
      remote_reaction(post, actor_uri, "nobody")

      token = mastodon_token(member, ["read"])

      [favourite] =
        conn |> mastodon_conn(token) |> get("/api/v1/notifications") |> json_response(200)

      assert favourite["account"]["acct"] == "nobody@social.example"
      assert favourite["account"]["avatar"] == Presenter.fallback_avatar()
    end
  end

  defp remote_reaction(post, actor_uri, handle) do
    Repo.insert!(%Reaction{
      post_id: post.id,
      actor_uri: actor_uri,
      handle: handle,
      kind: "like",
      received_at: DateTime.utc_now(:second)
    })
  end

  # The unmappable kinds are dropped **after** the read, so a full read can
  # still answer a short page with plenty left behind it. Judging "is there
  # more" by the answer's length calls that the end of the list.
  #
  # The newest entry here is the endorsement Mastodon has no type for, so a read
  # of two yields one item against a limit of two — which is exactly the shape
  # the old length test got wrong, and it goes red without the `more?` override.
  test "a page thinned by unmappable kinds still offers a next link", %{conn: conn} do
    member = insert(:activated_user)
    {:ok, post} = Posts.create_post(member, %{body: "Gemischt"})

    for _n <- 1..2, do: :ok = Posts.like_post(insert(:activated_user), post)

    # Backdated so the endorsement below is unambiguously the newest entry: the
    # rows are stamped to the second and the merge breaks a tie per source, not
    # across them, so three same-second rows order arbitrarily.
    Repo.update_all(Vutuv.Posts.PostLike,
      set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60)]
    )

    # A real endorsement **row**, with its endorser: the notification feed reads
    # `user_tag_endorsements` and inner-joins the endorser, so neither
    # `notify_endorsement/3` on its own (a webhook and a broadcast) nor a row
    # with no `user_id` puts anything here to filter out.
    insert(:user_tag_endorsement,
      user_tag: insert(:user_tag, user: member, tag: insert(:tag)),
      user: insert(:activated_user)
    )

    token = mastodon_token(member, ["read"])
    conn = conn |> mastodon_conn(token) |> get("/api/v1/notifications?limit=2")

    assert length(json_response(conn, 200)) == 1
    assert [link] = Plug.Conn.get_resp_header(conn, "link")
    assert link =~ ~s(rel="next")
  end
end
