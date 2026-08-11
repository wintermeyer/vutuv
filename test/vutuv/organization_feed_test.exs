defmodule Vutuv.OrganizationFeedTest do
  @moduledoc """
  The feed a page reads (issue #1336) — what closes the loop the milestone
  opened: a page that publishes but cannot read is one-directional on purpose,
  and this is the other direction.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp reader_page, do: active_organization_for(insert(:activated_user))

  defp publishing_page(name, host) do
    owner = insert(:activated_user)

    organization =
      active_organization_for(owner, %{"name" => name, "website_url" => "https://#{host}"})

    {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
    {organization, owner}
  end

  defp feed_ids(page, opts \\ []) do
    page |> Posts.organization_feed_page(opts) |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)
  end

  test "carries the posts of the members and pages it follows" do
    page = reader_page()
    member = insert(:activated_user)
    {other, other_owner} = publishing_page("Zweite AG", "zweite.example")

    {:ok, from_member} = Posts.create_post(member, %{body: "Von einer Person."})

    {:ok, from_page} =
      Posts.create_organization_post(other, other_owner, %{body: "Von der Seite."})

    {:ok, _} = Social.follow_as_organization(page, member)
    {:ok, _} = Social.follow_as_organization(page, other)

    ids = feed_ids(page)
    assert from_member.id in ids
    assert from_page.id in ids
  end

  test "shows nothing from somebody it does not follow" do
    page = reader_page()
    stranger = insert(:activated_user)
    {:ok, _} = Posts.create_post(stranger, %{body: "Unbekannt."})

    assert feed_ids(page) == []
  end

  test "a restricted post never reaches a page" do
    page = reader_page()
    member = insert(:activated_user)
    {:ok, _} = Social.follow_as_organization(page, member)

    {:ok, open} = Posts.create_post(member, %{body: "Für alle."})

    {:ok, restricted} =
      Posts.create_post(member, %{
        body: "Nur für Follower.",
        denials: [%{"wildcard" => "non_followers"}]
      })

    # A denial names users, groups and follow relationships. A page is none of
    # those, so it can never *be* the intended audience — the anonymous public
    # gate is the honest reading, not a special case.
    ids = feed_ids(page)
    assert open.id in ids
    refute restricted.id in ids
  end

  test "the acting member's own engagement decorates the entries" do
    page = reader_page()
    member = insert(:activated_user)
    {:ok, post} = Posts.create_post(member, %{body: "Zum Liken."})
    {:ok, _} = Social.follow_as_organization(page, member)

    reader = insert(:activated_user)
    :ok = Posts.like_post(reader, post)

    # The bar under each card belongs to the person, not to the page — a page
    # has no likes of its own. What it must never do is change *what* the feed
    # contains: two publishers reading the same page see the same posts.
    assert feed_ids(page, viewer: reader) == feed_ids(page)
  end

  test "a muted follow drops that author, as it does on a member's feed" do
    page = reader_page()
    member = insert(:activated_user)
    {:ok, post} = Posts.create_post(member, %{body: "Stummgeschaltet."})
    {:ok, follow} = Social.follow_as_organization(page, member)

    assert post.id in feed_ids(page)

    follow |> Follow.mute_changeset(%{muted: true}) |> Repo.update!()

    assert feed_ids(page) == []
  end
end
