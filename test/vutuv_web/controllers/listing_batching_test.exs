defmodule VutuvWeb.ListingBatchingTest do
  @moduledoc """
  Findings [43]/[44]: the listing pages and the profile right rail used to run
  the per-row current_job/1 chain and a per-row user_follows_user?/2 query
  through card_list / the rail. The controllers now batch both, passing
  work_info_by_id and following_by_id assigns. These tests assert the rendered
  output is unchanged (job line + follow/unfollow controls) and that the page
  load stays at a small, constant number of queries regardless of row count.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Repo

  defp validated_user(attrs) do
    insert(:user, Keyword.merge([validated?: true], attrs))
    |> with_active_slug()
  end

  # The slug plug resolves /users/<slug>; the factory's active_slug needs a
  # matching, enabled Slug row.
  defp with_active_slug(user) do
    insert(:slug, value: user.active_slug, disabled: false, user: user)
    user
  end

  defp with_job(user, title, org) do
    insert(:work_experience,
      user: user,
      title: title,
      organization: org,
      end_month: nil,
      end_year: nil
    )

    user
  end

  describe "GET /listings/most_followed_users" do
    test "renders each user's name and current-job line", %{conn: conn} do
      alice = validated_user(first_name: "Alice") |> with_job("Captain", "Acme")
      bob = validated_user(first_name: "Bob")
      # Give Alice a follower so she sorts to the top, exercising the listing.
      insert(:connection, follower: bob, followee: alice)

      body = conn |> get(~p"/listings/most_followed_users") |> html_response(200)

      assert body =~ "Alice"
      assert body =~ "Bob"
      # The batched work-info string is rendered for the user with a job.
      assert body =~ "Captain @ Acme"
    end

    test "query count stays constant as the user count grows", %{conn: conn} do
      for n <- 1..15 do
        validated_user(first_name: "List#{n}") |> with_job("Eng#{n}", "Org#{n}")
      end

      conn_for = fn -> conn |> recycle() |> get(~p"/listings/most_followed_users") end

      {_, few} = count_queries(fn -> conn_for.() end)

      for n <- 16..40 do
        validated_user(first_name: "List#{n}") |> with_job("Eng#{n}", "Org#{n}")
      end

      {_, many} = count_queries(fn -> conn_for.() end)

      # Adding 25 more users must not add ~75 queries (the old per-row cost).
      # A tiny slack accommodates session/identity lookups that don't scale
      # with the listing; the listing itself must not grow with row count.
      assert many <= few + 2,
             "query count grew from #{few} to #{many}; the listing is not batched"
    end
  end

  describe "GET /users/:id/followers and /users/:id/followees" do
    test "render the follower/followee job lines", %{conn: conn} do
      owner = validated_user(first_name: "Owner")
      follower = validated_user(first_name: "Fan") |> with_job("Scout", "Talent Co")
      followee = validated_user(first_name: "Idol") |> with_job("Star", "Fame Inc")

      insert(:connection, follower: follower, followee: owner)
      insert(:connection, follower: owner, followee: followee)

      followers_body = conn |> get(~p"/users/#{owner}/followers") |> html_response(200)
      assert followers_body =~ "Fan"
      assert followers_body =~ "Scout @ Talent Co"

      followees_body =
        conn |> recycle() |> get(~p"/users/#{owner}/followees") |> html_response(200)

      assert followees_body =~ "Idol"
      assert followees_body =~ "Star @ Fame Inc"
    end
  end

  describe "GET /users/:id profile right rail (recommended users)" do
    test "renders recommended users with their job line and an unfollow control when followed",
         %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)

      # The recommended user the viewer already follows; their work line and the
      # unfollow control both come from the batched assigns.
      recommended = validated_user(first_name: "Recommendo") |> with_job("Advisor", "Guild")
      insert(:connection, follower: viewer, followee: recommended)

      # The profile being viewed; Social.most_followed_users/1 orders by
      # follower count, so give the recommended user a follower to surface them.
      owner = validated_user(first_name: "Owner")
      insert(:connection, follower: owner, followee: recommended)

      body = conn |> get(~p"/users/#{owner}") |> html_response(200)

      assert body =~ "Recommendo"
      assert body =~ "Advisor @ Guild"
      # Followed -> the rail shows the "Following" (unfollow) link, i.e. a DELETE
      # to a real connection id, not a follow POST.
      assert body =~ "Following"
    end
  end

  # Telemetry handlers are global, so under async tests a parallel test's query
  # would also fire ours. Ecto runs the handler synchronously in the process
  # that called Repo, and ConnTest dispatches in this very test process, so we
  # only count events emitted from `parent`.
  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:vutuv, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, :query} -> drain_queries(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
