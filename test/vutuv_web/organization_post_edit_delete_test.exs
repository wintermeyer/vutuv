defmodule VutuvWeb.OrganizationPostEditDeleteTest do
  @moduledoc """
  Editing and deleting a post published in an organization's name (issue #1334).

  The post card already offered both controls to a publisher — `Posts.author?/2`
  says yes for them — so these were live buttons from the day organization posts
  shipped. Delete raised: `broadcast_post_deleted/2` matched on a binary author
  id or a list, and an organization post has neither.

  Both powers follow the **role**, not the person: any current publisher may
  edit or delete, including one who did not write the post.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp setup_post(conn) do
    {conn, owner} = create_and_login_user(conn)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Erste Fassung."})
    %{conn: conn, owner: owner, organization: organization, post: post}
  end

  test "a publisher opens the edit page and saves", %{conn: conn} do
    %{conn: conn, post: post} = setup_post(conn)

    {:ok, view, html} = live(conn, ~p"/posts/#{post.id}/edit")
    assert html =~ "Erste Fassung."

    view
    |> form("#composer-form", %{"post" => %{"body" => "Zweite Fassung."}})
    |> render_submit()

    assert Posts.get_post(post.id).body == "Zweite Fassung."
  end

  test "a publisher deletes it, and the page's followers are told", %{conn: conn} do
    %{conn: conn, post: post, organization: organization} = setup_post(conn)

    follower = insert(:activated_user)
    {:ok, _} = Social.follow_organization(follower, organization)
    Vutuv.Activity.subscribe(follower.id)

    conn = delete(conn, ~p"/posts/#{post.id}")
    assert redirected_to(conn)
    refute Posts.get_post(post.id)

    # Their open feed has to drop the card. The recipients of an organization
    # post's deletion are the people who follow the page — the publishers never
    # had it in their own feeds.
    post_id = post.id
    assert_receive {:post_deleted, %{post_id: ^post_id}}
  end

  test "a publisher who did not write it may still delete it", %{conn: conn} do
    {conn, other} = create_and_login_user(conn)
    author = insert(:activated_user)
    organization = active_organization_for(author)
    {:ok, _} = Organizations.add_role(organization, author, "publisher", author)
    {:ok, _} = Organizations.add_role(organization, other, "publisher", author)
    {:ok, post} = Posts.create_organization_post(organization, author, %{body: "Von der Seite."})

    conn = delete(conn, ~p"/posts/#{post.id}")
    assert redirected_to(conn)
    refute Posts.get_post(post.id)
  end

  test "somebody off the team cannot delete it", %{conn: conn} do
    {stranger_conn, _stranger} = create_and_login_user(conn)
    owner = insert(:activated_user)
    organization = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Unseres."})

    stranger_conn |> delete(~p"/posts/#{post.id}") |> response(404)
    assert Posts.get_post(post.id)
  end
end
