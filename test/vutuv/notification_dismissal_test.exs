defmodule Vutuv.NotificationDismissalTest do
  @moduledoc """
  Clicking a browser notification marks that one event read
  (`Vutuv.Activity.mark_notification_seen/3`; its docs say why).

  What the per-kind table below guards is the **seam**: the live push names a
  row with `:source_id`, the tally excludes a row by id, and the two are
  written in different modules from different arguments. So each kind asserts
  that the pushed event and the derived feed item name the *same* row
  (`event_id/2`) and that dismissing it moves the count by exactly one. A kind
  whose push forgets the id, or names the wrong one, passes neither.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.PostsHelpers

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.Tags

  defp mentionable(attrs \\ []) do
    insert(:activated_user, Keyword.put_new(attrs, :username, unique_username()))
  end

  # Runs `fun`, then hands back the notification it pushed to `me`.
  defp pushed(me, fun) do
    Activity.subscribe(me.id)
    fun.()
    assert_receive {:new_notification, notification}
    notification
  end

  defp item_of_kind(user_id, kind) do
    user_id
    |> Activity.notifications_page(limit: 50)
    |> Map.fetch!(:entries)
    |> Enum.find(&(&1.kind == kind))
  end

  # One event of every everyday kind, each as the member on the receiving end
  # would get it: `{recipient, fun_that_makes_it_happen}`.
  defp fixture(:like) do
    me = insert(:user)
    other = insert(:user)
    mine = insert(:post, user: me)

    {me, fn -> :ok = Posts.like_post(other, mine) end}
  end

  defp fixture(:reply) do
    me = insert(:user)
    other = insert(:user)
    mine = insert(:post, user: me)

    {me, fn -> {:ok, _} = Posts.create_reply(other, mine, %{body: "Good point."}) end}
  end

  defp fixture(:mention) do
    me = mentionable()
    other = mentionable()

    {me, fn -> create_post!(other, %{body: "Ask @#{me.username} about it."}) end}
  end

  defp fixture(:follower) do
    me = insert(:user)
    other = insert(:user)

    {me, fn -> {:ok, _} = Social.follow(other, me.id) end}
  end

  defp fixture(:connection) do
    me = insert(:user)
    other = insert(:user)
    {:ok, _} = Social.follow(me, other.id)

    {me, fn -> {:ok, _} = Social.follow(other, me.id) end}
  end

  defp fixture(:endorsement) do
    me = insert(:user)
    other = insert(:user)
    user_tag = insert(:user_tag, user: me, tag: insert(:tag))

    {me,
     fn -> {:ok, _} = Tags.create_endorsement(%{user_id: other.id, user_tag_id: user_tag.id}) end}
  end

  describe "a live push names the row the feed counts" do
    for kind <- ~w(like reply mention follower connection endorsement) do
      test "#{kind}" do
        kind = unquote(kind)
        {me, act} = fixture(String.to_existing_atom(kind))

        notification = pushed(me, act)
        ref = Activity.dismiss_ref(notification)

        assert %{kind: ^kind} = ref,
               "the #{kind} push carries no dismissable reference"

        assert Activity.event_id(ref.kind, ref.source_id) == item_of_kind(me.id, kind).id,
               "the #{kind} push and its feed item name different rows"
      end
    end
  end

  describe "dismissing one notification" do
    for kind <- ~w(like reply mention follower connection endorsement) do
      test "#{kind} drops it from the unread count" do
        kind = unquote(kind)
        {me, act} = fixture(String.to_existing_atom(kind))

        ref = me |> pushed(act) |> Activity.dismiss_ref()
        before = Activity.unread_notification_count(me.id)
        assert before >= 1

        Activity.mark_notification_seen(me.id, ref.kind, ref.source_id)

        assert Activity.unread_notification_count(me.id) == before - 1
      end
    end

    test "leaves the member's other notifications alone" do
      {me, act} = fixture(:like)
      first = me |> pushed(act) |> Activity.dismiss_ref()
      other = insert(:user)
      {:ok, _} = Social.follow(other, me.id)

      assert Activity.unread_notification_count(me.id) == 2

      Activity.mark_notification_seen(me.id, first.kind, first.source_id)

      assert Activity.unread_notification_count(me.id) == 1
    end

    test "is idempotent, and only the first one asks for a recount" do
      {me, act} = fixture(:like)
      ref = me |> pushed(act) |> Activity.dismiss_ref()

      Activity.mark_notification_seen(me.id, ref.kind, ref.source_id)
      assert_receive :notifications_changed

      Activity.mark_notification_seen(me.id, ref.kind, ref.source_id)
      refute_receive :notifications_changed, 50

      assert Activity.unread_notification_count(me.id) == 0
    end

    test "ignores a kind or an id the browser made up" do
      {me, act} = fixture(:like)
      ref = me |> pushed(act) |> Activity.dismiss_ref()

      Activity.mark_notification_seen(me.id, "not_a_kind", ref.source_id)
      Activity.mark_notification_seen(me.id, ref.kind, "no-such-uuid")
      Activity.mark_notification_seen(me.id, ref.kind, nil)
      Activity.mark_notification_seen(nil, ref.kind, ref.source_id)

      assert Activity.unread_notification_count(me.id) == 1
    end

    test "still shows the row on the notifications page, marked read" do
      {me, act} = fixture(:like)
      notification = pushed(me, act)
      ref = Activity.dismiss_ref(notification)

      Activity.mark_notification_seen(me.id, ref.kind, ref.source_id)

      assert MapSet.member?(Activity.dismissed_event_ids(me.id), item_of_kind(me.id, "like").id)
      assert length(Activity.notifications_page(me.id, limit: 50).entries) == 1
    end

    test "opening /notifications clears the dismissals it has made redundant" do
      {me, act} = fixture(:like)
      ref = me |> pushed(act) |> Activity.dismiss_ref()
      Activity.mark_notification_seen(me.id, ref.kind, ref.source_id)

      Activity.mark_notifications_read(me.id)

      assert Activity.dismissed_event_ids(me.id) == MapSet.new()
      assert Activity.unread_notification_count(me.id) == 0
    end
  end

  describe "dismissable_kinds/0" do
    # Both halves come off the registry's `dismiss` entries, so a kind cannot
    # store dismissals the tally ignores. What is worth pinning is the shape of
    # the vocabulary: exactly one opt-out, and the extra name the two-event
    # severance needs. A new kind declaring `dismiss: [nil]` by rote fails
    # here and has to justify itself.
    test "every kind but the grouped one can be dismissed" do
      assert Activity.kinds() -- Activity.dismissable_kinds() == ["cv_update"]
    end

    test "the report-protection restore half has a name of its own" do
      assert "report_protection_restored" in Activity.dismissable_kinds()
    end
  end
end
