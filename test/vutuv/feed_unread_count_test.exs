defmodule Vutuv.FeedUnreadCountTest do
  @moduledoc """
  The figure behind the shell's "Feed" nav badge: how many cards a member will
  find above where they left off (`Vutuv.Posts.unread_feed_count/1`), measured
  against the marker `Vutuv.Posts.mark_feed_read/1` writes.

  Two of these tests are about what must **not** be in the number, and they are
  the reason the function is not a bare count: a post the reader wrote
  themselves is in their own feed, so without the reject a member who answers a
  post from its permalink page — away from the feed, where nothing marks it read
  — walks off badged for their own words. Both were calibrated by taking the
  reject back out.
  """
  use Vutuv.DataCase

  import Vutuv.PostsHelpers

  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.Tags

  # The reader, with their marker placed a minute back. Every timestamp the feed
  # compares has second precision and the count's window opens the second AFTER
  # the marker, so a reader marked read "now" would not see a post this test
  # creates in the same second — which is the right behaviour on the page and
  # useless in a test.
  defp reader(seconds_ago \\ 60) do
    insert(:activated_user,
      feed_read_at: NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds_ago)
    )
  end

  # Somebody the reader follows, so what they write reaches this feed.
  defp followed_author(reader) do
    author = insert(:activated_user)
    Social.follow(reader, author.id)
    author
  end

  test "counts a followee's post that arrived after the marker" do
    reader = reader()
    author = followed_author(reader)
    create_post!(author, %{body: "arrived while you were away"})

    assert Posts.unread_feed_count(reader) == 1
  end

  test "ignores what was already there when the feed was last read" do
    reader = reader(60)
    author = followed_author(reader)

    create_post!(author, %{body: "you saw this one"}) |> backdate_post!(120)

    assert Posts.unread_feed_count(reader) == 0
  end

  test "a member with no marker is owed nothing" do
    reader = insert(:activated_user, feed_read_at: nil)
    author = followed_author(reader)
    create_post!(author, %{body: "brand new"})

    assert Posts.unread_feed_count(reader) == 0
  end

  test "does not count the reader's own post" do
    reader = reader()
    create_post!(reader, %{body: "I wrote this myself"})

    assert Posts.unread_feed_count(reader) == 0
  end

  test "does not count the reader's own repost" do
    reader = reader()
    author = followed_author(reader)
    post = create_post!(author, %{body: "worth passing on"}) |> backdate_post!(120)

    :ok = Posts.repost_post(reader, post)

    assert Posts.unread_feed_count(reader) == 0
  end

  test "counts somebody else's repost of a post the reader has already seen" do
    reader = reader()
    author = insert(:activated_user)
    sharer = followed_author(reader)
    post = create_post!(author, %{body: "old news, new messenger"}) |> backdate_post!(120)

    :ok = Posts.repost_post(sharer, post)

    assert Posts.unread_feed_count(reader) == 1
  end

  test "counts a followed tag's post from somebody the reader does not follow" do
    reader = reader()
    {:ok, _follow} = Tags.follow_tag(reader, insert(:tag, name: "Elixir").id)

    create_post!(insert(:activated_user), %{body: "found by its tag", tags: "Elixir"})

    assert Posts.unread_feed_count(reader) == 1
  end

  test "stops at the cap" do
    reader = reader()
    author = followed_author(reader)
    for n <- 1..3, do: create_post!(author, %{body: "post #{n}"})

    assert Posts.unread_feed_count(reader, cap: 2) == 2
  end

  describe "mark_feed_read/1" do
    test "moves the marker and tells the member's open shells to empty" do
      reader = reader()
      author = followed_author(reader)
      create_post!(author, %{body: "arrived while you were away"})

      Vutuv.Activity.subscribe(reader.id)
      :ok = Posts.mark_feed_read(reader)

      # A bare atom, like `:notifications_read`: the marker itself does not
      # travel, because a recount re-reads the member.
      assert_receive :feed_read

      assert Posts.unread_feed_count(reader.id) == 0
    end

    test "the id clause counts against the stored marker, not a stale struct" do
      reader = reader()
      author = followed_author(reader)
      create_post!(author, %{body: "arrived while you were away"})

      :ok = Posts.mark_feed_read(reader)

      # `reader` is the struct as it was loaded — the shape a shell holds from
      # its own mount, an hour after another tab has read the feed. The struct
      # clause still answers from that old marker; the id clause is the one a
      # recount takes, and it asks the database.
      assert Posts.unread_feed_count(reader) == 1
      assert Posts.unread_feed_count(reader.id) == 0
    end

    test "is a no-op without a member" do
      assert Posts.mark_feed_read(nil) == :ok
    end
  end
end
