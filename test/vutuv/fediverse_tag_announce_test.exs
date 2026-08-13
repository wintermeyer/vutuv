defmodule Vutuv.FediverseTagAnnounceTest do
  @moduledoc """
  A topic carries its posts to the people who followed it (issue #1330, the
  last slice): a public post tagged `#elixir` is `Announce`d by
  `@elixir@tags.<host>` to everyone who subscribed to the topic from their own
  server.

  The gates are the point of this file. A tag has no opt-in of its own, so the
  one thing standing between a member who chose not to federate and the open
  internet is the author check here.

  `async: false`: points `:fediverse_tag_host` at a known host, which is global.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Posts

  @tag_host "tags.example.test"

  setup do
    original = Application.fetch_env(:vutuv, :fediverse_tag_host)
    Application.put_env(:vutuv, :fediverse_tag_host, @tag_host)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :fediverse_tag_host, was)
        :error -> Application.delete_env(:vutuv, :fediverse_tag_host)
      end
    end)

    :ok
  end

  defp followed_topic do
    n = System.unique_integer([:positive])
    tag = insert(:tag, name: "Elixir #{n}", slug: "elixir_#{n}")

    {:ok, _} =
      Fediverse.add_tag_follower(tag, %{
        actor_uri: "https://remote.example/users/frida#{n}",
        inbox_uri: "https://remote.example/users/frida#{n}/inbox"
      })

    tag
  end

  defp federating_author, do: insert(:activated_user, fediverse_followers?: true)

  defp tag_deliveries(tag),
    do: Repo.all(from(d in Delivery, where: d.tag_id == ^tag.id))

  test "a public post reaches the followers of the topic it carries" do
    tag = followed_topic()
    author = federating_author()

    {:ok, post} = Posts.create_post(author, %{body: "Neues von hier.", tags: tag.name})

    assert [delivery] = tag_deliveries(tag)
    assert delivery.inbox_uri == "https://remote.example/users/frida#{suffix(tag)}/inbox"

    announce = Jason.decode!(delivery.activity_json)
    assert announce["type"] == "Announce"
    # The actor is the topic, not the author: it is the topic these people
    # subscribed to.
    assert announce["actor"] =~ "//#{@tag_host}" and
             String.ends_with?(announce["actor"], "/#{tag.slug}")

    # The object is the note's own id, so the remote server fetches the post
    # from the author's actor and renders it as a boost.
    assert announce["object"] =~ "/#{author.username}/posts/#{post.id}"
  end

  test "a hashtag in the body carries the post as well as a chip does" do
    tag = followed_topic()
    author = federating_author()

    {:ok, _post} = Posts.create_post(author, %{body: "Gebaut mit ##{tag.slug}."})

    assert [_delivery] = tag_deliveries(tag)
  end

  test "an author who does not federate is never carried out by a topic" do
    tag = followed_topic()
    author = insert(:activated_user, fediverse_followers?: false)

    {:ok, _post} = Posts.create_post(author, %{body: "Bleibt hier.", tags: tag.name})

    # The whole reason a tag needs no opt-in of its own: what it may carry is
    # decided by each author, at this moment.
    assert tag_deliveries(tag) == []
  end

  test "a restricted post stays inside, whatever tag is on it" do
    tag = followed_topic()
    author = federating_author()
    denied = insert(:activated_user)

    {:ok, _post} =
      Posts.create_post(author, %{
        body: "Nur für einige.",
        tags: tag.name,
        denials: [%{"denied_user_id" => denied.id}]
      })

    # An audience the author narrowed must not widen because a topic was
    # attached to it.
    assert tag_deliveries(tag) == []
  end

  test "an alias never announces the post its canonical already carries" do
    canonical = followed_topic()
    n = System.unique_integer([:positive])

    other_name =
      insert(:tag,
        name: "Alias #{n}",
        slug: "alias_#{n}",
        merged_into_id: canonical.id
      )

    author = federating_author()
    {:ok, _post} = Posts.create_post(author, %{body: "Einmal reicht.", tags: canonical.name})

    assert tag_deliveries(other_name) == []
    assert length(tag_deliveries(canonical)) == 1
  end

  test "a topic nobody follows queues nothing" do
    n = System.unique_integer([:positive])
    lonely = insert(:tag, name: "Einsam #{n}", slug: "einsam_#{n}")
    author = federating_author()

    {:ok, _post} = Posts.create_post(author, %{body: "Niemand hört zu.", tags: lonely.name})

    assert tag_deliveries(lonely) == []
    # And no keypair was minted for a topic that had nothing to send.
    refute Fediverse.get_tag_actor(lonely)
  end

  test "publishing a post does the announcing on its own" do
    tag = followed_topic()
    author = federating_author()

    # Publishing alone has to reach it, or the feature only works in tests:
    # nothing here calls `announce_to_tag_followers/1`.
    {:ok, _post} = Posts.create_post(author, %{body: "Frisch.", tags: tag.name})

    assert [_delivery] = tag_deliveries(tag)
  end

  defp suffix(tag), do: tag.slug |> String.split("_") |> List.last()
end
