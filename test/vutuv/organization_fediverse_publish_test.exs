defmodule Vutuv.OrganizationFediversePublishTest do
  @moduledoc """
  A federating page's post reaches its remote followers (issue #1334) — the
  last functional piece of that half, and what the whole chain was for.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.PostDelivery
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp publishing_page(opts \\ []) do
    owner = insert(:activated_user)
    page = active_organization_for(owner)
    {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

    page =
      page
      |> Ecto.Changeset.change(Enum.into(opts, %{fediverse_followers?: true, username: "acme"}))
      |> Repo.update!()

    {:ok, _} = Fediverse.ensure_organization_actor(page)
    {page, owner}
  end

  defp remote_follower(page, inbox \\ "https://social.example/users/alice/inbox") do
    {:ok, follower} =
      Fediverse.add_organization_follower(page, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: inbox
      })

    follower
  end

  test "a page's post is queued to its remote followers as the page" do
    {page, owner} = publishing_page()
    remote_follower(page)

    {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Neu bei uns."})

    delivery = Repo.one!(from(d in Delivery, where: d.organization_id == ^page.id))

    # The sender is the page, not the member who pressed publish — that person
    # stays internal, exactly as they do on the vutuv-facing card.
    assert is_nil(delivery.user_id)
    assert delivery.inbox_uri == "https://social.example/users/alice/inbox"

    activity = Jason.decode!(delivery.activity_json)
    assert activity["type"] == "Create"
    assert activity["actor"] == Docs.actor_url(page)
    assert activity["object"]["attributedTo"] == Docs.actor_url(page)
    assert activity["object"]["content"] =~ "Neu bei uns."

    # The Note's id is the page's permalink, which is what a federated post is
    # identified BY — so it must match what the site itself serves.
    assert activity["object"]["id"] =~ "/organizations/#{page.slug}/posts/#{post.id}"
    assert activity["object"]["id"] =~ Posts.path(post) |> String.trim_leading("/")
  end

  test "the takedown ledger records the page, so a revocation can be addressed" do
    {page, owner} = publishing_page()
    remote_follower(page)

    {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Später zurückgenommen."})

    ledger = Repo.one!(from(d in PostDelivery, where: d.post_id == ^post.id))
    assert ledger.organization_id == page.id
    assert is_nil(ledger.user_id)
    assert ledger.inbox_uri == "https://social.example/users/alice/inbox"
  end

  test "a page that has not opted in publishes nothing outward" do
    {page, owner} = publishing_page(fediverse_followers?: false)
    remote_follower(page)

    {:ok, _} = Posts.create_organization_post(page, owner, %{body: "Bleibt hier."})

    assert Repo.aggregate(from(d in Delivery, where: d.organization_id == ^page.id), :count) == 0
    assert Repo.aggregate(PostDelivery, :count) == 0
  end

  test "a federating page with no remote followers queues nothing" do
    {page, owner} = publishing_page()

    {:ok, _} = Posts.create_organization_post(page, owner, %{body: "Niemand da."})

    # Nothing to deliver is not an error, and it must not leave an empty row
    # behind for the deliverer to trip over.
    assert Repo.aggregate(from(d in Delivery, where: d.organization_id == ^page.id), :count) == 0
  end

  test "a member's post is unaffected" do
    author = insert(:activated_user, fediverse_followers?: true)
    {:ok, _} = Fediverse.ensure_actor(author)

    {:ok, _} =
      Fediverse.add_follower(author, %{
        actor_uri: "https://social.example/users/bob",
        inbox_uri: "https://social.example/users/bob/inbox"
      })

    {:ok, _} = Posts.create_post(author, %{body: "Von einer Person."})

    delivery = Repo.one!(from(d in Delivery, where: d.user_id == ^author.id))
    assert is_nil(delivery.organization_id)
  end
end
