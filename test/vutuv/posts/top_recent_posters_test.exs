defmodule Vutuv.Posts.TopRecentPostersTest do
  @moduledoc """
  The "Who to follow" candidate pool of the profile card
  (`Posts.top_recent_posters/2`): the members who posted within the window,
  ranked by the hearts their in-window posts collected, post count as the
  tie-break. Async-safe: only factory sequences, no shared literals, and the
  sandbox keeps each test's posts invisible to the others.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Posts

  defp days_ago(days), do: NaiveDateTime.add(NaiveDateTime.utc_now(), -days, :day)

  test "ranks the window's posters by hearts, then by post count" do
    hearted = insert_activated_user()
    liked_post = insert(:post, user: hearted)
    :ok = Posts.like_post(insert_activated_user(), liked_post)

    busy = insert_activated_user()
    insert(:post, user: busy)
    insert(:post, user: busy)

    quiet = insert_activated_user()
    insert(:post, user: quiet)

    # The liker never posted, so they are not in the pool at all.
    assert Enum.map(Posts.top_recent_posters(28, 10), & &1.id) ==
             [hearted.id, busy.id, quiet.id]
  end

  test "only members who posted inside the window qualify" do
    outsider = insert_activated_user()
    old = insert(:post, user: outsider, inserted_at: days_ago(30))
    :ok = Posts.like_post(insert_activated_user(), old)

    assert Posts.top_recent_posters(28, 10) == []
  end

  test "hearts on posts from before the window do not count" do
    # A veteran whose likes all sit on an old post ranks below a member whose
    # fresh post collected one - only in-window hearts speak for the feed a
    # new follower would actually get.
    veteran = insert_activated_user()
    old = insert(:post, user: veteran, inserted_at: days_ago(30))
    :ok = Posts.like_post(insert_activated_user(), old)
    insert(:post, user: veteran)

    fresh = insert_activated_user()
    :ok = Posts.like_post(insert_activated_user(), insert(:post, user: fresh))

    assert Enum.map(Posts.top_recent_posters(28, 10), & &1.id) == [fresh.id, veteran.id]
  end

  test "unconfirmed accounts never surface, and the limit caps the list" do
    unconfirmed = insert(:user)
    insert(:post, user: unconfirmed)

    first = insert_activated_user()
    :ok = Posts.like_post(insert_activated_user(), insert(:post, user: first))
    second = insert_activated_user()
    insert(:post, user: second)

    assert Enum.map(Posts.top_recent_posters(28, 1), & &1.id) == [first.id]
    refute unconfirmed.id in Enum.map(Posts.top_recent_posters(28, 10), & &1.id)
  end
end
