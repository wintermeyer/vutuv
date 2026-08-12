defmodule VutuvWeb.OrganizationEngagementLiveTest do
  @moduledoc """
  Liking and resharing **as a page** from the feed (issue #1336).

  The surface follows the composer's precedent rather than inventing one:
  `/feed` stays the *member's* feed while they are switched into a page — it is
  their reading surface — but what they *write* there goes out in the page's
  name. The composer has worked that way since #1335, so the action bar does
  too, and there is no separate place to go to react as a page.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp recycle_login(conn),
    do: conn |> recycle() |> Map.put(:secret_key_base, conn.secret_key_base)

  test "the like button acts in the page's name, not the publisher's", %{conn: conn} do
    {conn, owner} = create_and_login_user(conn)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

    # Somebody the publisher follows, so their post is in the feed to react to.
    author = insert_activated_user()
    {:ok, _} = Vutuv.Social.follow(owner, author.id)
    {:ok, post} = Posts.create_post(author, %{body: "Hallo Welt"})

    conn = conn |> post(~p"/organizations/#{page.slug}/act_as") |> recycle_login()

    {:ok, feed, _html} = live(conn, ~p"/feed")

    feed
    |> element("#post-actions-post-#{post.id}-like")
    |> render_click()

    # The row belongs to the page, with the publisher recorded internally.
    assert [like] =
             Vutuv.Repo.all(from(l in Vutuv.Posts.PostLike, where: l.post_id == ^post.id))

    assert like.organization_id == page.id
    assert is_nil(like.user_id)
    assert like.acting_user_id == owner.id

    # And the bar reads back the PAGE's state, so the heart is filled for the
    # whole team rather than for whoever happened to press it.
    assert Posts.post_engagement(post.id, page).liked?
    refute Posts.post_engagement(post.id, owner).liked?
  end

  test "the same button is the member's own when not speaking as a page", %{conn: conn} do
    {conn, me} = create_and_login_user(conn)

    author = insert_activated_user()
    {:ok, _} = Vutuv.Social.follow(me, author.id)
    {:ok, post} = Posts.create_post(author, %{body: "Hallo Welt"})

    {:ok, feed, _html} = live(conn, ~p"/feed")

    feed
    |> element("#post-actions-post-#{post.id}-like")
    |> render_click()

    assert [like] =
             Vutuv.Repo.all(from(l in Vutuv.Posts.PostLike, where: l.post_id == ^post.id))

    assert like.user_id == me.id
    assert is_nil(like.organization_id)
  end
end
