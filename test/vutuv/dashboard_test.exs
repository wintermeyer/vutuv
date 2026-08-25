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

  describe "online_members/2" do
    # `ShellLive` tracks on every page's socket, so a presence diff fires at
    # site-wide socket churn — and the dashboard re-read this list on every one
    # of them, sending the whole online id set to Postgres so it could hand back
    # the ten largest. Ids are UUID v7 and the ordering is on `id` alone, so the
    # same ten can be picked before the query for nothing.
    test "asks the database about a bounded slice, however many are online" do
      members = for _ <- 1..40, do: insert(:activated_user)
      online = MapSet.new(members, & &1.id)

      # Measured on the **parameters**, not on the query count: the count was
      # always one, and what used to grow without bound was the id list inside
      # it. A query-count assertion here would pass with or without the fix.
      {result, params} = with_query_params(fn -> Dashboard.online_members(online) end)

      assert length(result) == 10

      # Ecto sends the `IN` list as ONE array parameter, so it is that array
      # that has to be measured — `length(params)` is 2 whatever happens, which
      # is how the first version of this assertion passed with the fix reverted.
      assert [sent_ids | _rest] = params
      assert is_list(sent_ids), "the telemetry probe did not see the id list"

      assert length(sent_ids) <= 20,
             "sent #{length(sent_ids)} ids to Postgres for a list of ten; " <>
               "the whole online set is going over the wire on every presence diff"

      # And it is still the ten newest, which is what the page shows.
      newest = members |> Enum.map(& &1.id) |> Enum.sort(:desc) |> Enum.take(10)
      assert Enum.map(result, & &1.id) |> Enum.sort(:desc) == newest
    end

    test "an id presence still holds for a member who is gone does not shrink the list" do
      members = for _ <- 1..15, do: insert(:activated_user)

      # A socket outlived its member. The id sorts above every real one, so a
      # slice of exactly ten would come back nine short of what it promises.
      stale = "01ffffff-ffff-7fff-bfff-ffffffffffff"
      online = MapSet.new([stale | Enum.map(members, & &1.id)])

      assert length(Dashboard.online_members(online)) == 10
    end

    test "nobody online is no query at all" do
      {result, queries} =
        Vutuv.QueryCounter.count_queries(fn -> Dashboard.online_members(MapSet.new()) end,
          matching: ~r/FROM "users"/
        )

      assert result == []
      assert queries == 0
    end
  end

  describe "registrations_today/0" do
    test "counts only today's confirmed sign-ups", ctx do
      insert(:activated_user, at(ctx.today_start))
      insert(:activated_user, at(ctx.today_start))
      insert(:user, [email_confirmed?: false] ++ at(ctx.today_start))
      insert(:activated_user, at(ctx.yesterday_start))

      assert Dashboard.registrations_today() == 2
    end

    test "is zero on a day nobody joined", ctx do
      insert(:activated_user, at(ctx.yesterday_start))

      assert Dashboard.registrations_today() == 0
    end

    test "agrees with the dashboard tile", ctx do
      insert(:activated_user, at(ctx.today_start))

      assert Dashboard.registrations_today() == Dashboard.activity_snapshot().registrations_today
    end
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

  # The parameters of the one `users` query `fun` runs. `QueryCounter` matches on
  # SQL text and counts; what changed here is the size of the payload, so this
  # reads it off the same telemetry event.
  defp with_query_params(fun) do
    parent = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:vutuv, :repo, :query],
      fn _event, _measure, metadata, _config ->
        if self() == parent and metadata.query =~ ~s(FROM "users") do
          send(parent, {ref, metadata.params})
        end
      end,
      nil
    )

    try do
      result = fun.()

      params =
        receive do
          {^ref, params} -> params
        after
          0 -> []
        end

      {result, params}
    after
      :telemetry.detach(handler)
    end
  end
end
