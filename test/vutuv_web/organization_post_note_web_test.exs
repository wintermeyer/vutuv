defmodule VutuvWeb.OrganizationPostNoteWebTest do
  @moduledoc """
  The ActivityPub rendering of a page's post permalink.

  `note_url/2` builds a page post's federated id as
  `/organizations/:slug/posts/:id`, so that URL **is** the object id every
  remote server holding one of our page posts fetches — to verify it, to thread
  a reply under it, to check it still exists. The member permalink beside it has
  answered such a request with the Note since the beginning.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page_with_post(body \\ "Von uns.") do
    owner = insert(:activated_user)

    page =
      active_organization_for(owner)
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: "acme"})
      |> Repo.update!()

    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(page, owner, %{body: body})
    # The owner travels with them: a test that needs to publish a second post
    # as the page's publisher should take it here rather than read the roles
    # table back out with a schemaless query.
    {page, post, owner}
  end

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  test "the page post permalink answers ActivityPub with its Note", %{conn: conn} do
    {page, post, _owner} = federating_page_with_post()

    conn = conn |> ap() |> get(~p"/organizations/#{page.slug}/posts/#{post.id}")

    # It answered **500** until v7.274.1: the action ran the accept header
    # through `AgentDocs.negotiate/2`, which knows nothing about
    # `application/activity+json`, while the member permalink had had its own
    # branch all along. Every page post we federate names this URL as its id.
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/activity+json"

    note = Jason.decode!(conn.resp_body)
    assert note["type"] == "Note"
    assert note["id"] =~ "/organizations/#{page.slug}/posts/#{post.id}"
    assert note["attributedTo"] =~ "/organizations/#{page.slug}/actor"
    assert note["content"] =~ "Von uns."
  end

  test "a page that does not federate serves no Note", %{conn: conn} do
    {page, post, _owner} = federating_page_with_post()

    page
    |> Ecto.Changeset.change(%{fediverse_followers?: false})
    |> Repo.update!()

    # Same rule the member permalink applies: nothing is federated for an
    # account that does not, so the HTML page is all there is.
    conn = conn |> ap() |> get(~p"/organizations/#{page.slug}/posts/#{post.id}")
    refute conn.status == 200
  end

  test "the HTML permalink is untouched", %{conn: conn} do
    {page, post, _owner} = federating_page_with_post()

    assert conn |> get(~p"/organizations/#{page.slug}/posts/#{post.id}") |> html_response(200) =~
             "Von uns."
  end

  describe "a page post that refused machines (issue #2107)" do
    # A page post carries the same switch a member's does — the composer offers
    # it whoever is being published for — and all three of these surfaces
    # answered as if it did not. Measured on the un-fixed branch: the AP request
    # returned 200 with the whole Note, `.json` carried the body under
    # `ai-train=yes`, and the HTML page stamped no `X-Robots-Tag` at all.
    defp withheld_page_post(body \\ "Interne Preisliste.") do
      {page, post, owner} = federating_page_with_post(body)
      {:ok, post} = Posts.update_post(post, %{body: body, noindex_noai: "true"})
      {page, post, owner}
    end

    test "is not handed over as a Note", %{conn: conn} do
      {page, post, _owner} = withheld_page_post()

      conn = conn |> ap() |> get(~p"/organizations/#{page.slug}/posts/#{post.id}")

      refute conn.status == 200
      refute conn.resp_body =~ "Preisliste"
    end

    test "says so in its agent document instead of inviting a crawler", %{conn: conn} do
      {page, post, _owner} = withheld_page_post()

      conn = get(conn, "/organizations/#{page.slug}/posts/#{post.id}.json")

      # The headers are what a crawler acts on, so they are what is asserted.
      assert json_response(conn, 200)["body_markdown"] =~ "Preisliste"
      assert [signal] = get_resp_header(conn, "content-signal")
      assert signal =~ "ai-train=no"
      assert signal =~ "search=no"
      assert signal =~ "ai-input=no"
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
    end

    test "stamps the HTML page with the robots header", %{conn: conn} do
      {page, post, _owner} = withheld_page_post()

      conn = get(conn, ~p"/organizations/#{page.slug}/posts/#{post.id}")

      assert html_response(conn, 200) =~ "Preisliste"
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
    end

    test "leaves the page's public timeline, and with it the feed and the page document" do
      {page, post, owner} = withheld_page_post()
      {:ok, open} = Posts.create_organization_post(page, owner, %{body: "Offen."})

      %{entries: public} = Posts.organization_posts_page(page, nil)
      %{entries: theirs} = Posts.organization_posts_page(page, owner)

      assert Enum.map(public, & &1.id) == [open.id]
      # …and the team still sees their own withheld post on their own page.
      assert post.id in Enum.map(theirs, & &1.id)
    end
  end
end
