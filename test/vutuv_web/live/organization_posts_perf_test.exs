defmodule VutuvWeb.OrganizationPostsPerfTest do
  @moduledoc """
  Query-count regression tests for the two organization surfaces that render
  `<.post_card>`: the page itself (`/organizations/:slug`, **public**) and its
  feed (`/organizations/:slug/feed`).

  Both handed the card no `engagement`, so every card's action bar fell back to
  its own `Posts.post_engagement/2` — ten extra round trips on the page and
  twenty on the feed, paid by anonymous visitors on the public one. The same
  N+1 the profile fixed in v7.201 and the feed guards in
  `post_feed_live_test.exs`.

  `async: false` because `count_queries_global/1` watches every process, so an
  async neighbour's queries would land in the window.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Posts
  alias Vutuv.QueryCounter

  # The action-bar engagement SELECT is the only query built from this
  # hand-written fragment, so its text is a stable signature.
  @engagement_query ~r/post_likes l WHERE l\.post_id/

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp page_with_posts(conn, count) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Vutuv.Organizations.add_role(organization, owner, "publisher", owner)

    for n <- 1..count//1 do
      {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Beitrag #{n}"})
    end

    {conn, organization}
  end

  test "the organization page batches engagement into one query", %{conn: conn} do
    {conn, organization} = page_with_posts(conn, 4)

    {conn, engagement_queries} =
      QueryCounter.count_queries(
        fn -> get(conn, ~p"/organizations/#{organization.slug}") end,
        matching: @engagement_query
      )

    assert html_response(conn, 200) =~ "Beitrag 1"

    assert engagement_queries == 1,
           "expected the organization page to batch engagement into one query, " <>
             "got #{engagement_queries} — one per card is the N+1 this guards"
  end

  test "an anonymous visitor pays the same single query", %{conn: conn} do
    {_conn, organization} = page_with_posts(conn, 4)
    anonymous = build_conn()

    {anonymous, engagement_queries} =
      QueryCounter.count_queries(
        fn -> get(anonymous, ~p"/organizations/#{organization.slug}") end,
        matching: @engagement_query
      )

    assert html_response(anonymous, 200) =~ "Beitrag 1"
    assert engagement_queries <= 1
  end

  # A page's feed carries what the page *follows*, not what it published, so
  # the cards here come from a second page it subscribed to.
  test "the organization feed batches engagement into one query", %{conn: conn} do
    {conn, reader} = page_with_posts(conn, 0)

    author_owner = insert(:activated_user)

    author =
      active_organization_for(author_owner, %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })

    {:ok, _} = Vutuv.Organizations.add_role(author, author_owner, "publisher", author_owner)

    for n <- 1..4 do
      {:ok, _} = Posts.create_organization_post(author, author_owner, %{body: "Beitrag #{n}"})
    end

    {:ok, _} = Vutuv.Social.follow_as_organization(reader, author)

    conn = post(conn, ~p"/organizations/#{reader.slug}/act_as")

    {conn, engagement_queries} =
      QueryCounter.count_queries(
        fn -> get(conn, ~p"/organizations/#{reader.slug}/feed") end,
        matching: @engagement_query
      )

    assert html_response(conn, 200) =~ "Beitrag 1"

    assert engagement_queries == 1,
           "expected the organization feed to batch engagement into one query, " <>
             "got #{engagement_queries} — one per card is the N+1 this guards"
  end
end
