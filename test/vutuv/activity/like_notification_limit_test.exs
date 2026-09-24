defmodule Vutuv.Activity.LikeNotificationLimitTest do
  use Vutuv.DataCase, async: true
  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts

  defp user(attrs \\ []), do: insert(:activated_user, attrs)

  # Likes `post` `n` times from fresh strangers and hands back the likers and
  # what the author heard, in order.
  defp like_times(post, n) do
    for _ <- 1..n do
      liker = user()
      :ok = Posts.like_post(liker, post)
      {liker, next_like()}
    end
    |> Enum.unzip()
  end

  # The author's next like notification, marked `quiet: true` when it came as
  # the quiet message `Activity.notify/2` sends for what interrupts nobody.
  defp next_like do
    receive do
      {:new_notification, %{kind: "like"} = notification} -> notification
      {:quiet_notification, %{kind: "like"} = notification} -> notification
    after
      1_000 -> flunk("no like notification")
    end
  end

  defp quiet?(notification), do: Map.get(notification, :quiet, false)

  test "the first ten likes ring, the ones after them arrive quietly" do
    author = user()
    post = create_post!(author, %{body: "popular"})
    Activity.subscribe(author.id)

    {_likers, heard} = like_times(post, 12)

    assert Enum.map(heard, &quiet?/1) == List.duplicate(false, 10) ++ [true, true]
    # Only what rang counts on the bell.
    assert Activity.unread_notification_count(author.id) == 10
    # The page still lists every like.
    assert length(Activity.notifications_page(author.id, kinds: ["like"]).entries) == 12
  end

  test "the cap closes with a final notice and later likes stay quiet" do
    author = user(like_notification_cap: "25")
    post = create_post!(author, %{body: "viral"})
    Activity.subscribe(author.id)

    {_likers, heard} = like_times(post, 26)

    assert %{milestone: 25, final?: true} = Enum.at(heard, 24)
    assert quiet?(Enum.at(heard, 25))
    assert Enum.count(heard, &(not quiet?(&1))) == 11
    assert Activity.unread_notification_count(author.id) == 11

    assert VutuvWeb.NotificationLine.title_and_body(Enum.at(heard, 24)) ==
             {"Your post now has 25 likes. We will not notify you about further likes of it.",
              nil}
  end

  # Every account that existed before the cap did has no value of its own
  # (NULL), which inherits the installation default: 50 unless an admin
  # changed it. No backfill writes "50" into those rows on purpose, because an
  # explicit value would stop a later change of the default from reaching them.
  test "an account with no cap of its own gets the default of 50" do
    author = user()
    assert author.like_notification_cap == nil
    post = create_post!(author, %{body: "old account"})
    Activity.subscribe(author.id)

    {_likers, heard} = like_times(post, 51)

    assert %{milestone: 50, final?: true} = Enum.at(heard, 49)
    assert quiet?(Enum.at(heard, 50))
  end

  test "a milestone rings once, however often the count passes it" do
    author = user()
    post = create_post!(author, %{body: "wobbly"})
    Activity.subscribe(author.id)

    {likers, heard} = like_times(post, 25)
    assert %{milestone: 25} = List.last(heard)

    :ok = Posts.unlike_post(List.last(likers), post)
    :ok = Posts.like_post(user(), post)
    assert quiet?(next_like())
  end

  test "a muted post interrupts nobody, and the mute is the author's alone" do
    author = user()
    other = user()
    post = create_post!(author, %{body: "leave me be"})
    {:ok, _reply} = Posts.create_reply(other, post, %{body: "first!"})
    assert Activity.unread_notification_count(author.id) == 1

    assert {:error, :not_author} = Posts.mute_notifications(other, post, true)
    {:ok, post} = Posts.mute_notifications(author, post, true)
    # What was waiting about it leaves the bell at once.
    assert Activity.unread_notification_count(author.id) == 0

    Activity.subscribe(author.id)
    Activity.subscribe(other.id)

    :ok = Posts.like_post(user(), post)
    assert_receive {:quiet_notification, %{kind: "like"}}

    {:ok, _reply} = Posts.create_reply(user(), post, %{body: "second!"})
    assert_receive {:quiet_notification, %{kind: "reply"}}
    # The earlier replier still hears about the thread they wrote in.
    assert_receive {:new_notification, %{kind: "thread"}}

    assert Activity.unread_notification_count(author.id) == 0
    assert Activity.unread_notifications(author.id, 10).items == []

    # Unmuting brings back what arrived meanwhile, and the bell rings again.
    {:ok, _post} = Posts.mute_notifications(author, post, false)
    assert Activity.unread_notification_count(author.id) == 3
    :ok = Posts.like_post(user(), post)
    assert_receive {:new_notification, %{kind: "like"}}
  end
end
