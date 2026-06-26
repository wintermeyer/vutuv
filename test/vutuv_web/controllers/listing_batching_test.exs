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

  import Vutuv.QueryCounter

  alias Vutuv.Repo

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
      alice = insert_activated_user(first_name: "Alice") |> with_job("Captain", "Acme")
      bob = insert_activated_user(first_name: "Bob")
      # Both need a visible follower to surface: the listing ranks members who
      # have at least one, most followers first.
      insert(:follow, follower: bob, followee: alice)
      insert(:follow, follower: alice, followee: bob)

      body = conn |> get(~p"/listings/most_followed_users") |> html_response(200)

      assert body =~ "Alice"
      assert body =~ "Bob"
      # The batched work-info string is rendered for the user with a job.
      assert body =~ "Captain @ Acme"
    end

    test "shows the explanatory note and a descriptive page title", %{conn: conn} do
      body = conn |> get(~p"/listings/most_followed_users") |> html_response(200)

      # The intro note explains why this is, for now, just a most-followed list.
      assert body =~ "So for now"
      assert body =~ "1,000 users with the most followers"

      # The HTML <title> is no longer the bare site name.
      assert body =~ ~r{<title[^>]*>[^<]*Most Followed Users[^<]*</title>}
    end

    test "lists a member's top tags linked to the tag page, with an overflow count",
         %{conn: conn} do
      fan = insert_activated_user(first_name: "Fan")
      star = insert_activated_user(first_name: "Star")
      # A follower so the star surfaces on the listing (it ranks members who
      # have at least one visible follower).
      insert(:follow, follower: fan, followee: star)

      popular = insert(:tag, name: "Bridgebuilding", slug: "bridgebuilding")
      popular_ut = insert(:user_tag, user: star, tag: popular)
      # Endorse the popular tag so it ranks first among the member's tags.
      insert(:user_tag_endorsement, user_tag: popular_ut, user: fan)

      # Five more tags, so the member has six in all: four are shown, two overflow.
      for n <- 1..5 do
        insert(:user_tag, user: star, tag: insert(:tag, name: "Extra #{n}", slug: "extra-#{n}"))
      end

      body = conn |> get(~p"/listings/most_followed_users") |> html_response(200)

      # The most endorsed tag is shown and links to its public tag page.
      assert body =~ ~r{<a[^>]+href="/tags/bridgebuilding"[^>]*>[^<]*Bridgebuilding}
      # Six tags total, only four shown, so two overflow into the "+N more" count.
      assert body =~ "+2 more tags"
    end

    test "loading the tag summary keeps the query count constant", %{conn: conn} do
      fan = insert_activated_user(first_name: "Fan")

      tagged = fn n ->
        u = insert_activated_user(first_name: "Tagged#{n}")
        insert(:follow, follower: fan, followee: u)
        ut = insert(:user_tag, user: u, tag: insert(:tag, name: "Tag#{n}"))
        insert(:user_tag_endorsement, user_tag: ut, user: fan)
      end

      for n <- 1..10, do: tagged.(n)

      conn_for = fn -> conn |> recycle() |> get(~p"/listings/most_followed_users") end
      {_, few} = count_queries(fn -> conn_for.() end)

      for n <- 11..25, do: tagged.(n)

      {_, many} = count_queries(fn -> conn_for.() end)

      # The per-user tag summary is one batched query, so adding tagged members
      # must not grow the page's query count.
      assert many <= few + 2,
             "query count grew from #{few} to #{many}; the tag summary is not batched"
    end

    test "query count stays constant as the user count grows", %{conn: conn} do
      # A shared follower so every listed member surfaces (the listing only
      # ranks members with at least one visible follower).
      fan = insert_activated_user(first_name: "Fan")

      for n <- 1..15 do
        u = insert_activated_user(first_name: "List#{n}") |> with_job("Eng#{n}", "Org#{n}")
        insert(:follow, follower: fan, followee: u)
      end

      conn_for = fn -> conn |> recycle() |> get(~p"/listings/most_followed_users") end

      {_, few} = count_queries(fn -> conn_for.() end)

      for n <- 16..40 do
        u = insert_activated_user(first_name: "List#{n}") |> with_job("Eng#{n}", "Org#{n}")
        insert(:follow, follower: fan, followee: u)
      end

      {_, many} = count_queries(fn -> conn_for.() end)

      # Adding 25 more users must not add ~75 queries (the old per-row cost).
      # A tiny slack accommodates session/identity lookups that don't scale
      # with the listing; the listing itself must not grow with row count.
      assert many <= few + 2,
             "query count grew from #{few} to #{many}; the listing is not batched"
    end
  end

  describe "GET /:slug/followers and /:slug/following" do
    test "render the follower/followee job lines", %{conn: conn} do
      owner = insert_activated_user(first_name: "Owner")
      follower = insert_activated_user(first_name: "Fan") |> with_job("Scout", "Talent Co")
      followee = insert_activated_user(first_name: "Idol") |> with_job("Star", "Fame Inc")

      insert(:follow, follower: follower, followee: owner)
      insert(:follow, follower: owner, followee: followee)

      followers_body = conn |> get(~p"/#{owner}/followers") |> html_response(200)
      assert followers_body =~ "Fan"
      assert followers_body =~ "Scout @ Talent Co"

      followees_body =
        conn |> recycle() |> get(~p"/#{owner}/following") |> html_response(200)

      assert followees_body =~ "Idol"
      assert followees_body =~ "Star @ Fame Inc"
    end

    test "lists a follower's top tags linked to the tag page, with an overflow count",
         %{conn: conn} do
      owner = insert_activated_user(first_name: "Owner")
      follower = insert_activated_user(first_name: "Fan")
      insert(:follow, follower: follower, followee: owner)

      popular = insert(:tag, name: "Bridgebuilding", slug: "bridgebuilding")
      popular_ut = insert(:user_tag, user: follower, tag: popular)
      # Endorse the popular tag so it ranks first among the follower's tags.
      insert(:user_tag_endorsement, user_tag: popular_ut, user: owner)

      # Five more tags, so the follower has six in all: four shown, two overflow.
      for n <- 1..5 do
        insert(:user_tag,
          user: follower,
          tag: insert(:tag, name: "Extra #{n}", slug: "f-extra-#{n}")
        )
      end

      body = conn |> get(~p"/#{owner}/followers") |> html_response(200)

      # The most endorsed tag is shown and links to its public tag page.
      assert body =~ ~r{<a[^>]+href="/tags/bridgebuilding"[^>]*>[^<]*Bridgebuilding}
      # Six tags total, only four shown, so two overflow into the "+N more" count.
      assert body =~ "+2 more tags"
    end

    test "lists a followee's top tags linked to the tag page, with an overflow count",
         %{conn: conn} do
      owner = insert_activated_user(first_name: "Owner")
      idol = insert_activated_user(first_name: "Idol")
      insert(:follow, follower: owner, followee: idol)

      popular = insert(:tag, name: "Stagecraft", slug: "stagecraft")
      popular_ut = insert(:user_tag, user: idol, tag: popular)
      insert(:user_tag_endorsement, user_tag: popular_ut, user: owner)

      for n <- 1..5 do
        insert(:user_tag, user: idol, tag: insert(:tag, name: "More #{n}", slug: "g-more-#{n}"))
      end

      body = conn |> get(~p"/#{owner}/following") |> html_response(200)

      assert body =~ ~r{<a[^>]+href="/tags/stagecraft"[^>]*>[^<]*Stagecraft}
      assert body =~ "+2 more tags"
    end

    test "loading the per-row tag summary keeps the query count constant", %{conn: conn} do
      owner = insert_activated_user(first_name: "Owner")

      tagged_follower = fn n ->
        u = insert_activated_user(first_name: "Fan#{n}")
        insert(:follow, follower: u, followee: owner)
        ut = insert(:user_tag, user: u, tag: insert(:tag, name: "Tag#{n}"))
        insert(:user_tag_endorsement, user_tag: ut, user: owner)
      end

      for n <- 1..10, do: tagged_follower.(n)

      conn_for = fn -> conn |> recycle() |> get(~p"/#{owner}/followers") end
      {_, few} = count_queries(fn -> conn_for.() end)

      for n <- 11..25, do: tagged_follower.(n)

      {_, many} = count_queries(fn -> conn_for.() end)

      # The per-row tag summary is one batched query, so adding tagged followers
      # must not grow the page's query count.
      assert many <= few + 2,
             "query count grew from #{few} to #{many}; the tag summary is not batched"
    end
  end

  describe "GET /users/:id profile right rail (recommended users)" do
    test "renders recommended users with their job line and an unfollow control when followed",
         %{conn: conn} do
      {conn, viewer} = create_and_login_user(conn)

      # The recommended user the viewer already follows; their work line and the
      # unfollow control both come from the batched assigns.
      recommended =
        insert_activated_user(first_name: "Recommendo") |> with_job("Advisor", "Guild")

      insert(:follow, follower: viewer, followee: recommended)

      # The profile being viewed; Social.most_followed_users/1 orders by
      # follower count, so give the recommended user a follower to surface them.
      owner = insert_activated_user(first_name: "Owner")
      insert(:follow, follower: owner, followee: recommended)

      body = conn |> get(~p"/#{owner}") |> html_response(200)

      assert body =~ "Recommendo"
      assert body =~ "Advisor @ Guild"
      # Followed -> the rail shows the "Following" (unfollow) link, i.e. a DELETE
      # to a real connection id, not a follow POST.
      assert body =~ "Following"
    end

    test "never recommends the profile owner to themselves", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)

      # The profile owner is the most-followed member, so the default
      # most_followed_users/1 query would otherwise surface them at the top of
      # their own "who to follow" rail.
      owner = insert_activated_user(first_name: "Popular")
      insert(:follow, follower: insert_activated_user(), followee: owner)
      insert(:follow, follower: insert_activated_user(), followee: owner)

      # A second member so the rail still has someone genuine to recommend.
      other = insert_activated_user(first_name: "Somebody")
      insert(:follow, follower: insert_activated_user(), followee: other)

      conn = get(conn, ~p"/#{owner}")
      assert html_response(conn, 200)

      recommended_ids = Enum.map(conn.assigns.recommended_users, & &1.id)
      refute owner.id in recommended_ids
      assert other.id in recommended_ids
    end
  end

  describe "GET /tags/:slug (related/recommended user lists)" do
    test "renders the job lines and stays at a constant query count as users grow", %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      tag = insert(:tag)

      tag_user = fn n ->
        user = insert_activated_user(first_name: "Tagged#{n}") |> with_job("Eng#{n}", "Org#{n}")
        insert(:user_tag, user: user, tag: tag)
      end

      for n <- 1..5, do: tag_user.(n)

      body = conn |> get(~p"/tags/#{tag}") |> html_response(200)
      assert body =~ "Tagged1"
      # The batched work-info string renders for the recommended users.
      assert body =~ "Eng1 @ Org1"

      {_, few} = count_queries(fn -> conn |> recycle() |> get(~p"/tags/#{tag}") end)

      for n <- 6..15, do: tag_user.(n)

      {_, many} = count_queries(fn -> conn |> recycle() |> get(~p"/tags/#{tag}") end)

      # Doubling the rendered rows must not add per-row work-info/follow
      # queries (the old cost was ~4 queries per row).
      assert many <= few + 2,
             "query count grew from #{few} to #{many}; the tag page lists are not batched"
    end
  end
end
