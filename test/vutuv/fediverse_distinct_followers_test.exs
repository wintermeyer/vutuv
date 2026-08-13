defmodule Vutuv.FediverseDistinctFollowersTest do
  @moduledoc """
  `Vutuv.Fediverse.distinct_follower_count/0`: how many remote **accounts**
  follow anything here, counted once per account rather than once per follow.

  The figure feeds the top bar's people total (`Vutuv.PeopleCounter`), where a
  single Mastodon account subscribed to two members and three tags has to read
  as one person, not five.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower

  defp follower(actor_uri, attrs) do
    Repo.insert!(
      struct(
        %Follower{actor_uri: actor_uri, inbox_uri: actor_uri <> "/inbox"},
        attrs
      )
    )
  end

  defp tag do
    n = System.unique_integer([:positive])
    insert(:tag, name: "topic#{n}", slug: "topic#{n}")
  end

  test "one remote account following a member, a page and a topic counts once" do
    before = Fediverse.distinct_follower_count()
    actor = "https://remote.example/users/frida"

    follower(actor, user_id: insert(:activated_user).id)
    follower(actor, organization_id: insert(:organization).id)
    follower(actor, tag_id: tag().id)

    assert Fediverse.distinct_follower_count() == before + 1
  end

  test "two accounts on the same server count twice" do
    before = Fediverse.distinct_follower_count()
    user = insert(:activated_user)

    follower("https://remote.example/users/frida", user_id: user.id)
    follower("https://remote.example/users/knut", user_id: user.id)

    assert Fediverse.distinct_follower_count() == before + 2
  end

  test "an actor on our own host is not a remote account (and neither is www.)" do
    before = Fediverse.distinct_follower_count()
    host = VutuvWeb.Endpoint.host()
    user = insert(:activated_user)

    follower("https://#{host}/users/local", user_id: user.id)
    follower("https://www.#{host}/users/other", tag_id: tag().id)
    follower("https://#{Fediverse.tag_host()}/topic", user_id: user.id)

    # These count nobody: the number answers "how many people out there follow
    # this installation", and a local actor is already in the member half of the
    # total, so counting it here would count the same person twice.
    assert Fediverse.distinct_follower_count() == before
  end

  test "an unparseable actor URI still counts as one account" do
    # It is a stored follower either way, and dropping it would make the total
    # silently smaller than the follower browser's own list.
    before = Fediverse.distinct_follower_count()

    follower("acct:frida@remote.example", user_id: insert(:activated_user).id)

    assert Fediverse.distinct_follower_count() == before + 1
  end
end
