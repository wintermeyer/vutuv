defmodule Vutuv.DashboardTest do
  @moduledoc """
  The live operational snapshot behind the admin home dashboard: posts, direct
  messages and confirmed sign-ups for today and yesterday (German calendar day),
  plus the timestamp of the most recent post and message.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.BerlinTime
  alias Vutuv.Dashboard

  setup do
    today = BerlinTime.today()
    {today_start, _} = BerlinTime.day_bounds_utc(today)
    {yesterday_start, _} = BerlinTime.day_bounds_utc(Date.add(today, -1))
    {old_start, _} = BerlinTime.day_bounds_utc(Date.add(today, -5))

    %{today_start: today_start, yesterday_start: yesterday_start, old_start: old_start}
  end

  defp at(naive), do: [inserted_at: naive, updated_at: naive]

  defp message(naive) do
    conversation = insert_conversation_between(insert(:user), insert(:user))
    insert(:message, [conversation: conversation] ++ at(naive))
  end

  test "an empty system is all zeros with no last post/message" do
    assert Dashboard.activity_snapshot() == %{
             posts_today: 0,
             posts_yesterday: 0,
             last_post_at: nil,
             messages_today: 0,
             messages_yesterday: 0,
             last_message_at: nil,
             registrations_today: 0,
             registrations_yesterday: 0
           }
  end

  test "buckets posts by the German calendar day, ignoring older days", ctx do
    insert(:post, at(ctx.today_start))
    insert(:post, at(ctx.today_start))
    insert(:post, at(ctx.yesterday_start))
    insert(:post, at(ctx.old_start))

    snapshot = Dashboard.activity_snapshot()

    assert snapshot.posts_today == 2
    assert snapshot.posts_yesterday == 1
  end

  test "buckets direct messages by the German calendar day", ctx do
    message(ctx.today_start)
    message(ctx.yesterday_start)
    message(ctx.yesterday_start)
    message(ctx.old_start)

    snapshot = Dashboard.activity_snapshot()

    assert snapshot.messages_today == 1
    assert snapshot.messages_yesterday == 2
  end

  test "counts only confirmed-by-PIN sign-ups, like the daily report", ctx do
    insert(:activated_user, at(ctx.today_start))
    insert(:user, [email_confirmed?: false] ++ at(ctx.today_start))
    insert(:activated_user, at(ctx.yesterday_start))
    insert(:activated_user, at(ctx.old_start))

    snapshot = Dashboard.activity_snapshot()

    assert snapshot.registrations_today == 1
    assert snapshot.registrations_yesterday == 1
  end

  test "reports the timestamp of the most recently created post and message", ctx do
    insert(:post, at(ctx.yesterday_start))
    # Inserted last, so it carries the highest (newest) UUID v7 id.
    insert(:post, at(ctx.today_start))
    message(ctx.today_start)

    snapshot = Dashboard.activity_snapshot()

    # compare/2, not ==: the stored timestamps round-trip at the column's
    # precision (posts second, messages microsecond), so the structs differ
    # in their microsecond field while naming the same instant.
    assert NaiveDateTime.compare(snapshot.last_post_at, ctx.today_start) == :eq
    assert NaiveDateTime.compare(snapshot.last_message_at, ctx.today_start) == :eq
  end

  describe "newest_members/1" do
    test "lists confirmed members newest first, skipping unconfirmed ones" do
      _oldest = insert(:activated_user)
      newest = insert(:activated_user)
      insert(:user, email_confirmed?: false)

      # Ids are UUID v7, so the last-inserted member sorts first.
      assert [first | _] = Dashboard.newest_members()
      assert first.id == newest.id
      assert length(Dashboard.newest_members()) == 2
    end

    test "caps the list at ten" do
      for _ <- 1..11, do: insert(:activated_user)

      assert length(Dashboard.newest_members()) == 10
    end
  end

  describe "online_members/1" do
    test "returns [] for an empty presence set without querying" do
      assert Dashboard.online_members(MapSet.new()) == []
    end

    test "resolves the presence ids to member rows, newest first" do
      older = insert(:user)
      newer = insert(:user)
      _absent = insert(:user)

      members = Dashboard.online_members(MapSet.new([older.id, newer.id]))

      assert Enum.map(members, & &1.id) == [newer.id, older.id]
    end
  end
end
