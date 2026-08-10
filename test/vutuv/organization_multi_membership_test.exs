defmodule Vutuv.OrganizationMultiMembershipTest do
  @moduledoc """
  A member belongs to as many organizations as they like, with a different set
  of roles on each.

  Two independent things could have capped this and neither does, which is what
  these tests pin down: the unique index is on `[organization_id, user_id, role]`
  (issue #1333), so it constrains a member *within* one page and says nothing
  across pages; and every listing that groups a member's pages has to group by
  the page rather than collapse to one. `member_organizations/1` in particular
  chunks its rows, and a chunk is only correct while rows of the same page stay
  adjacent — which is why its query orders by the page id as well as the name,
  and why two pages sharing a name are worth a test of their own.

  `async: false` because the helpers flip the global
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

  describe "a member in several organizations" do
    setup do
      member = insert(:activated_user)

      # Three pages, three different standings: their own, one they only write
      # for, one they only recruit for.
      own =
        active_organization_for(member, %{
          "name" => "Anton AG",
          "website_url" => "https://anton.example"
        })

      {:ok, _} = Organizations.add_role(own, member, "publisher", member)

      {second, second_owner} =
        active_organization(%{"name" => "Berta AG", "website_url" => "https://berta.example"})

      {:ok, _} = Organizations.set_roles(second, member, ["publisher", "admin"], second_owner)

      {third, third_owner} =
        active_organization(%{"name" => "Cäsar AG", "website_url" => "https://caesar.example"})

      {:ok, _} = Organizations.add_role(third, member, "recruiter", third_owner)

      %{member: member, own: own, second: second, third: third}
    end

    test "holds its own roles on each, with no interference between them", ctx do
      %{member: member, own: own, second: second, third: third} = ctx

      assert Organizations.roles_of(own, member) == ["owner", "publisher"]
      assert Organizations.roles_of(second, member) == ["admin", "publisher"]
      assert Organizations.roles_of(third, member) == ["recruiter"]

      # The predicates answer per page, never globally.
      assert Organizations.owner?(own, member)
      refute Organizations.owner?(second, member)
      assert Organizations.publisher?(second, member)
      refute Organizations.publisher?(third, member)
    end

    test "member_organizations lists every page once, with all of its roles", ctx do
      %{member: member, own: own, second: second, third: third} = ctx

      listed = Organizations.member_organizations(member)
      by_id = Map.new(listed, fn {organization, roles} -> {organization.id, roles} end)

      assert map_size(by_id) == 3
      assert by_id[own.id] == ["owner", "publisher"]
      assert by_id[second.id] == ["admin", "publisher"]
      assert by_id[third.id] == ["recruiter"]
    end

    test "actable_organizations offers exactly the pages they may speak for", ctx do
      %{member: member, own: own, second: second, third: third} = ctx

      ids = member |> Organizations.actable_organizations() |> Enum.map(& &1.id)

      assert own.id in ids
      assert second.id in ids
      # Recruiting for a page is not speaking for it.
      refute third.id in ids
    end

    test "publishes in each name in turn, and each page keeps only its own posts", ctx do
      %{member: member, own: own, second: second, third: third} = ctx

      {:ok, _} = Posts.create_organization_post(own, member, %{body: "Von Anton."})
      {:ok, _} = Posts.create_organization_post(second, member, %{body: "Von der zweiten."})

      assert [%{body: "Von Anton."}] = Posts.organization_posts_page(own, member).entries
      assert [%{body: "Von der zweiten."}] = Posts.organization_posts_page(second, member).entries
      assert [] == Posts.organization_posts_page(third, member).entries

      # And none of it lands on the member's own timeline.
      {entries, _total} = Posts.author_posts_page(member, member, %{})
      assert entries == []
    end

    test "losing a role on one page leaves the others untouched", ctx do
      %{member: member, own: own, second: second} = ctx
      second_owner = hd(Organizations.list_team(second)).user

      {:ok, ["admin"]} = Organizations.set_roles(second, member, ["admin"], second_owner)

      refute Organizations.publisher?(second, member)
      assert Organizations.publisher?(own, member)
    end
  end

  test "two organizations sharing a name are still two rows in the member's list" do
    member = insert(:activated_user)

    first =
      active_organization_for(member, %{
        "name" => "Gleicher Name GmbH",
        "website_url" => "https://eins.example"
      })

    second =
      active_organization_for(member, %{
        "name" => "Gleicher Name GmbH",
        "website_url" => "https://zwei.example"
      })

    # `member_organizations/1` chunks adjacent rows into one entry per page, so
    # a same-name pair is the case where an ordering by name alone would fuse
    # two pages into one. Its query orders by the id as well for exactly this.
    listed = Organizations.member_organizations(member)
    ids = Enum.map(listed, fn {organization, _roles} -> organization.id end)

    assert length(listed) == 2
    assert first.id in ids
    assert second.id in ids
  end
end
