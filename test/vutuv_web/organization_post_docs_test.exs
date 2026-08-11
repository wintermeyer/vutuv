defmodule VutuvWeb.OrganizationPostDocsTest do
  @moduledoc """
  The machine renderings of a timeline that contains an organization post
  (issues #1334, #1336).

  The `users`-join sweep covered `posts.ex`; these are the same shape one layer
  up, in the doc builders. `PostDoc.timeline_entry/1` names the author with
  `full_name(post.user)`, so every reader who follows a page broke their own
  `/feed.md` / `/feed.json` — and the API's `GET /posts/:id` handed
  `PostDoc.build/3` a nil author.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

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

  test "the API serves an organization post as its own document kind", %{conn: conn} do
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Per API."})

    reader = insert(:activated_user)

    {:ok, token, _} =
      Vutuv.ApiAuth.create_pat(reader, %{"name" => "t", "scopes" => ["posts:read"]})

    json =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> get("/api/2.0/posts/#{post.id}")
      |> json_response(200)

    # The smaller document, not the member one with every field nil: an
    # organization post has no audience, no conversation, no remote reactions.
    assert json["type"] == "organization_post"
    assert json["author"]["name"] == organization.name
    refute json |> Jason.encode!() |> String.contains?(owner.username)
  end

  test "a follower's feed documents render the page's post", %{conn: conn} do
    {conn, member} = create_and_login_user(conn)
    {organization, owner} = active_organization()
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Aus dem Haus."})
    {:ok, _} = Social.follow_organization(member, organization)

    # The reader's own feed, as a machine document. The entry is named by the
    # page, never by the member who pressed publish.
    json = conn |> get(~p"/feed.json") |> json_response(200)

    entry = Enum.find(json["posts"], &(&1["excerpt"] =~ "Aus dem Haus."))
    assert entry
    assert entry["author"] == organization.name
    refute json |> Jason.encode!() |> String.contains?(owner.username)
  end
end
