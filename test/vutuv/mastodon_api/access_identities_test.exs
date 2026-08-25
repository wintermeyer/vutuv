defmodule Vutuv.MastodonApi.AccessIdentitiesTest do
  @moduledoc """
  `Access.identities/2` builds the OAuth consent screen's "act as" list: the
  member plus every page they may speak for, each with the scopes that identity
  may actually hold.

  `Organizations.member_organizations/1` hands it each page **with its roles**,
  and the function used to discard them (`{organization, _roles}`), then ask the
  role table again — once per requested scope inside `allowed_scopes/3`, plus
  once more for `acts_for?/2`. A member of three pages picking from eight scopes
  paid twenty-seven reads of rows the list it was iterating had just been built
  from.

  `async: false`: the organization helpers flip the global
  `:verify_organization_domains` flag and the DNS-resolver stub beside it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.MastodonApi.Access
  alias Vutuv.Organizations
  alias Vutuv.QueryCounter

  @scopes ~w(read:accounts read:statuses read:notifications write:statuses)

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp publishing_pages(owner, count) do
    for n <- 1..count do
      page =
        active_organization_for(owner, %{
          "name" => "Seite #{n} GmbH",
          "website_url" => "https://seite-#{n}.example"
        })

      {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)
      {:ok, page} = Organizations.set_mastodon_clients(page, true)
      page
    end
  end

  test "the list names the member and every page they publish for" do
    owner = insert(:activated_user, mastodon_clients?: true)
    [first, second] = publishing_pages(owner, 2)

    values = owner |> Access.identities(@scopes) |> Enum.map(& &1.value)

    assert "person" in values
    assert ("organization:" <> first.id) in values
    assert ("organization:" <> second.id) in values
  end

  # The read count must not grow with the number of scopes on the screen: the
  # roles are already in hand. Calibrated against the un-fixed code, where the
  # wide list ran 4x the reads of the narrow one.
  test "asking for more scopes does not cost more role-table reads" do
    owner = insert(:activated_user, mastodon_clients?: true)
    publishing_pages(owner, 2)

    {_narrow, few} =
      QueryCounter.count_queries(
        fn -> Access.identities(owner, ["read:accounts"]) end,
        matching: ~r/organization_roles/
      )

    {_wide, many} =
      QueryCounter.count_queries(
        fn -> Access.identities(owner, @scopes) end,
        matching: ~r/organization_roles/
      )

    assert many == few,
           "the consent screen ran #{many} role reads for #{length(@scopes)} scopes " <>
             "against #{few} for one — the roles it already holds are being re-read"
  end

  test "a page whose editorial role was withdrawn drops off the list" do
    owner = insert(:activated_user, mastodon_clients?: true)
    [page] = publishing_pages(owner, 1)

    assert Enum.any?(Access.identities(owner, @scopes), &(&1.subject.id == page.id))

    Repo.delete_all(
      from(r in Vutuv.Organizations.OrganizationRole,
        where: r.organization_id == ^page.id and r.role == "publisher"
      )
    )

    refute Enum.any?(Access.identities(owner, @scopes), &(&1.subject.id == page.id))
  end
end
