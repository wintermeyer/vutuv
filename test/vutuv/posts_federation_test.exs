defmodule Vutuv.PostsFederationTest do
  # The write paths of Vutuv.Posts feed follow-only federation: publishing,
  # editing and deleting a public post enqueues the matching activity for a
  # federating author's remote followers (Vutuv.Fediverse). async: false —
  # the global switch lives in the application env.
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Posts

  defp author_with_follower do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(user)

    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/inbox"
      })

    user
  end

  # Federates (opt-in + confirmed + actor) but has no remote followers, so their
  # own posts enqueue nothing — the right shape for the *reposted* author, whose
  # Note the Announce points at.
  defp federating_author do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(user)
    user
  end

  defp activities do
    Delivery
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.activity_json)["type"])
    |> Enum.sort()
  end

  defp only_activity do
    [delivery] = Repo.all(Delivery)
    Jason.decode!(delivery.activity_json)
  end

  test "publishing a public post federates a Create" do
    user = author_with_follower()

    create_post!(user, %{body: "Hallo Fediverse"})

    assert activities() == ["Create"]
  end

  test "a public reply federates too" do
    user = author_with_follower()
    parent = create_post!(insert(:activated_user), %{body: "parent"})

    {:ok, _reply} = Posts.create_reply(user, parent, %{body: "reply"})

    assert activities() == ["Create"]
  end

  test "editing federates an Update, restricting federates a Delete" do
    user = author_with_follower()
    post = create_post!(user, %{body: "v1"})
    Repo.delete_all(Delivery)

    {:ok, post} = Posts.update_post(post, %{body: "v2"})
    assert activities() == ["Update"]

    Repo.delete_all(Delivery)
    {:ok, _} = Posts.update_post(post, %{body: "v2", denials: [%{"wildcard" => "logged_out"}]})
    assert activities() == ["Delete"]
  end

  test "deleting a post federates a Delete" do
    user = author_with_follower()
    post = create_post!(user, %{body: "kurzlebig"})
    Repo.delete_all(Delivery)

    {:ok, _} = Posts.delete_post(post)

    assert activities() == ["Delete"]
  end

  test "restricted posts and non-federating authors enqueue nothing" do
    user = author_with_follower()
    create_post!(user, %{body: "geheim", denials: [%{"wildcard" => "logged_out"}]})

    plain = insert(:activated_user)
    create_post!(plain, %{body: "öffentlich, aber kein Opt-in"})

    assert activities() == []
  end

  test "reposting a federating author's public post federates an Announce" do
    reposter = author_with_follower()
    author = federating_author()
    post = create_post!(author, %{body: "boost mich"})
    Repo.delete_all(Delivery)

    :ok = Posts.repost_post(reposter, post)

    announce = only_activity()
    assert announce["type"] == "Announce"
    assert announce["actor"] =~ "/#{reposter.username}/actor"
    assert announce["object"] == "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"
  end

  test "un-reposting federates an Undo referencing the same Announce id" do
    reposter = author_with_follower()
    author = federating_author()
    post = create_post!(author, %{body: "boost mich"})
    Repo.delete_all(Delivery)

    :ok = Posts.repost_post(reposter, post)
    announce_id = only_activity()["id"]
    Repo.delete_all(Delivery)

    :ok = Posts.unrepost_post(reposter, post)

    undo = only_activity()
    assert undo["type"] == "Undo"
    assert undo["object"]["type"] == "Announce"
    assert undo["object"]["id"] == announce_id
  end

  test "reposting a non-federating author's post enqueues nothing" do
    reposter = author_with_follower()
    plain = insert(:activated_user)
    post = create_post!(plain, %{body: "öffentlich, aber kein Opt-in"})
    Repo.delete_all(Delivery)

    :ok = Posts.repost_post(reposter, post)

    assert activities() == []
  end

  test "reposting by a non-federating member enqueues nothing" do
    plain = insert(:activated_user)
    author = federating_author()
    post = create_post!(author, %{body: "boost mich"})
    Repo.delete_all(Delivery)

    :ok = Posts.repost_post(plain, post)

    assert activities() == []
  end

  test "an idempotent un-repost with nothing to undo enqueues nothing" do
    reposter = author_with_follower()
    author = federating_author()
    post = create_post!(author, %{body: "boost mich"})
    Repo.delete_all(Delivery)

    :ok = Posts.unrepost_post(reposter, post)

    assert activities() == []
  end
end
