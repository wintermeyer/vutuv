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
    {page, post}
  end

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  test "the page post permalink answers ActivityPub with its Note", %{conn: conn} do
    {page, post} = federating_page_with_post()

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
    {page, post} = federating_page_with_post()

    page
    |> Ecto.Changeset.change(%{fediverse_followers?: false})
    |> Repo.update!()

    # Same rule the member permalink applies: nothing is federated for an
    # account that does not, so the HTML page is all there is.
    conn = conn |> ap() |> get(~p"/organizations/#{page.slug}/posts/#{post.id}")
    refute conn.status == 200
  end

  test "the HTML permalink is untouched", %{conn: conn} do
    {page, post} = federating_page_with_post()

    assert conn |> get(~p"/organizations/#{page.slug}/posts/#{post.id}") |> html_response(200) =~
             "Von uns."
  end
end
