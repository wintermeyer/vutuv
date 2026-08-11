defmodule Vutuv.OrganizationFollowerNotificationTest do
  @moduledoc """
  A page follows you, and you are told (issue #1336).

  The badge and the list are built from two different queries over the same
  table: `count_followers/2` counts every row, `follower_items/3` inner-joins
  `users` to build the actor. That was harmless while only members could follow
  — and became a phantom unread the moment a page could (v7.249.0): the badge
  says one, the list shows nothing, and a badge that lies once is a badge nobody
  trusts again.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Activity
  alias Vutuv.Social

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp follower_entries(member) do
    member.id
    |> Activity.notifications_page(limit: 20)
    |> Map.fetch!(:entries)
    |> Enum.filter(&(&1.kind == "follower"))
  end

  test "the page shows up in the list, with its name and its own page's link" do
    page = active_organization_for(insert(:activated_user))
    member = insert(:activated_user)

    {:ok, _} = Social.follow_as_organization(page, member)

    assert [entry] = follower_entries(member)
    assert entry.actor_name == page.name
    assert entry.actor_kind == "organization"

    # The link must not be built from the param alone: a page's slug lives under
    # /organizations/:slug, while the root namespace belongs to member handles,
    # so `/#{param}` would point at somebody else entirely — or nowhere.
    assert entry.actor_param == page.slug
  end

  test "the unread count agrees with the list" do
    page = active_organization_for(insert(:activated_user))
    member = insert(:activated_user)
    person = insert(:activated_user)

    {:ok, _} = Social.follow(person, member.id)
    {:ok, _} = Social.follow_as_organization(page, member)

    assert length(follower_entries(member)) == 2
    assert Activity.unread_notification_count(member) == 2
  end

  test "a frozen page neither shows nor counts" do
    page = active_organization_for(insert(:activated_user))
    member = insert(:activated_user)

    {:ok, _} = Social.follow_as_organization(page, member)
    {:ok, _} = Vutuv.Organizations.admin_set_frozen(page, true)

    assert follower_entries(member) == []
    assert Activity.unread_notification_count(member) == 0
  end

  test "the member's own follower notifications still read as before" do
    member = insert(:activated_user)
    person = insert(:activated_user, first_name: "Frida", last_name: "Folger")

    {:ok, _} = Social.follow(person, member.id)

    assert [entry] = follower_entries(member)
    assert entry.actor_name =~ "Frida"
    assert entry.actor_kind == "user"
  end
end
