defmodule Vutuv.PostAuthorPreloadTest do
  @moduledoc """
  Every surface that draws a post's author dispatched on the **preloaded
  association** (`%Post{organization: %Organization{}}`) rather than on the
  `organization_id` column. That reads as a type check and behaves as a preload
  check: hand any of them a bare `%Post{}` straight out of a query and the
  organization clause quietly does not match, so the post is drawn as a
  member's — and the member is `nil`.

  It is the same shape as the `visible_to?/2` bug (a permission answer that
  depended on whether somebody remembered a preload), one layer up. These tests
  hand each surface a deliberately un-preloaded organization post.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias VutuvWeb.AgentDocs.PostDoc

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  # A post exactly as a query hands it over: no :user, no :organization.
  defp bare_organization_post do
    owner = insert(:activated_user)
    organization = active_organization_for(owner, %{"name" => "Bare AG"})
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Ohne Preload."})

    {Repo.get!(Post, post.id), organization}
  end

  test "author/1 answers the page even when nothing is preloaded" do
    {post, organization} = bare_organization_post()

    assert %Organization{id: id} = Posts.author(post)
    assert id == organization.id
  end

  test "author/1 answers the member even when nothing is preloaded" do
    author = insert(:activated_user)
    {:ok, post} = Posts.create_post(author, %{body: "Auch ohne Preload."})

    assert %User{id: id} = Posts.author(Repo.get!(Post, post.id))
    assert id == author.id
  end

  test "path/1 builds the page's permalink from the column, not the preload" do
    {post, organization} = bare_organization_post()

    assert Posts.path(post) == "/organizations/#{organization.slug}/posts/#{post.id}"
  end

  test "the agent timeline entry names the page without a preload" do
    {post, organization} = bare_organization_post()

    # timeline_entry/1 is what every listing's .md/.json/.xml sibling renders a
    # row with; a nil author there took the whole document down, not one line.
    entry = PostDoc.timeline_entry(%{post: post})

    assert entry.author == organization.name
    assert entry.url =~ "/organizations/#{organization.slug}/posts/#{post.id}"
  end
end
