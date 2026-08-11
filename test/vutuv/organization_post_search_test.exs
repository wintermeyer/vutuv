defmodule Vutuv.OrganizationPostSearchTest do
  @moduledoc """
  Organization posts in public search (issues #1334, #1336).

  They were absent, and absent in the way that is hardest to notice: the query
  inner-joined `users` to gate on the author's confirmed address, so a post with
  no member author matched nothing. A missing search result looks like a missing
  post, not like a bug.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag.
  """
  use Vutuv.DataCase, async: false

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

  defp publishing_organization(overrides \\ %{}) do
    {organization, owner} = active_organization(overrides)
    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {organization, owner}
  end

  defp found_ids(term), do: term |> Posts.search_public() |> Enum.map(& &1.id)

  test "a page's post is findable, with its author preloaded for rendering" do
    {organization, owner} = publishing_organization()

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor gebaut."})

    assert [found] = Posts.search_public("Quantenkompressor")
    assert found.id == post.id

    # The results page names and links the author, so the row has to carry one.
    assert found.organization.id == organization.id
    assert Posts.path(found) =~ organization.slug
  end

  test "member posts are unaffected, and both kinds come back together" do
    member = insert(:activated_user)
    {:ok, mine} = Posts.create_post(member, %{body: "Quantenkompressor privat."})

    {organization, owner} = publishing_organization()

    {:ok, theirs} =
      Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor bei uns."})

    ids = found_ids("Quantenkompressor")
    assert mine.id in ids
    assert theirs.id in ids
  end

  test "a page that is not public keeps its posts out of search" do
    {organization, owner} = publishing_organization()

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor."})

    assert post.id in found_ids("Quantenkompressor")

    # Frozen by moderation: the page is off the public site, and so is what it
    # said. The member equivalent is a hidden author's posts vanishing.
    {:ok, _} = Organizations.admin_set_frozen(organization, true)
    refute post.id in found_ids("Quantenkompressor")
  end

  test "a post still held by the image scan is not findable either" do
    {organization, owner} = publishing_organization()

    {:ok, post} =
      Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor."})

    Repo.update!(Ecto.Changeset.change(post, images_pending?: true))

    refute post.id in found_ids("Quantenkompressor")
  end
end
