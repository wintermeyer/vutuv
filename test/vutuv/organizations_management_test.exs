defmodule Vutuv.OrganizationsManagementTest do
  @moduledoc """
  Organization team roles, multi-domain management and name aliases (issue #930).
  `async: false` because the domain-add/verify flow flips the global
  `:verify_organization_domains` flag and injects a DNS resolver, like the #929
  verification tests.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  describe "deletable?/1" do
    # Issue #932's documented rule: a page with job postings must be archived,
    # not hard-deleted (deleting would orphan/destroy its postings). The guard
    # existed but was never wired, so the owner delete button worked anyway.
    test "an organization with postings is archive-only; one without stays deletable" do
      {organization, owner} = active_organization()
      assert Organizations.deletable?(organization)

      old = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 86_400, :second)

      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^owner.id),
        set: [inserted_at: old]
      )

      Vutuv.JobsHelpers.publish_job!(Repo.reload!(owner), %{}, organization: organization)

      refute Organizations.deletable?(organization)
    end
  end

  describe "suggest_members/2" do
    # The roles typeahead must honour the same visibility gate as every other
    # people-search surface: never surface never-activated sign-ups or
    # moderation-hidden accounts. Usernames/names are hardcoded here, which is
    # safe because this module is async: false.
    test "excludes unconfirmed and moderation-hidden accounts" do
      future = NaiveDateTime.add(NaiveDateTime.utc_now(:second), 7 * 86_400)

      visible = insert(:activated_user, username: "suggestme-visible", first_name: "Suggestme")
      _unconfirmed = insert(:user, username: "suggestme-unconfirmed", first_name: "Suggestme")

      _frozen =
        insert(:activated_user,
          username: "suggestme-frozen",
          first_name: "Suggestme",
          frozen_at: NaiveDateTime.utc_now(:second)
        )

      _suspended =
        insert(:activated_user,
          username: "suggestme-suspended",
          first_name: "Suggestme",
          suspended_until: future
        )

      _deactivated =
        insert(:activated_user,
          username: "suggestme-deactivated",
          first_name: "Suggestme",
          deactivated_at: NaiveDateTime.utc_now(:second)
        )

      ids = Organizations.suggest_members("suggestme") |> Enum.map(& &1.id)

      assert ids == [visible.id]
    end
  end

  describe "roles" do
    test "owner powers vs admin vs recruiter" do
      {organization, owner} = active_organization()
      admin = insert(:activated_user)
      recruiter = insert(:activated_user)
      stranger = insert(:activated_user)

      {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)
      {:ok, _} = Organizations.add_role(organization, recruiter, "recruiter", owner)

      assert Organizations.owner?(organization, owner)
      refute Organizations.owner?(organization, admin)

      assert Organizations.can_edit_page?(organization, owner)
      assert Organizations.can_edit_page?(organization, admin)
      refute Organizations.can_edit_page?(organization, recruiter)

      assert Organizations.can_manage_roles?(organization, owner)
      refute Organizations.can_manage_roles?(organization, admin)
      refute Organizations.can_manage_domains?(organization, recruiter)

      # A recruiter is still staff (sees a frozen/pending page)…
      assert Organizations.can_manage?(organization, recruiter)
      # …but a stranger is not.
      refute Organizations.can_manage?(organization, stranger)
    end

    test "add_role notifies the member, allows a second role and rejects the same one twice" do
      {organization, owner} = active_organization()
      member = insert(:activated_user)

      assert {:ok, _role} = Organizations.add_role(organization, member, "admin", owner)

      # A member may hold several roles (issue #1333) …
      assert {:ok, _role} = Organizations.add_role(organization, member, "publisher", owner)
      assert Organizations.roles_of(organization, member) == ["admin", "publisher"]

      # … but not the same one twice.
      assert {:error, :already_member} =
               Organizations.add_role(organization, member, "admin", owner)
    end

    test "publisher is never implied by owner or admin" do
      {organization, owner} = active_organization()
      admin = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, admin, "admin", owner)

      # The whole point of the role: administering a page is not speaking for it,
      # so a freshly claimed page cannot post until its owner says so once.
      refute Organizations.publisher?(organization, owner)
      refute Organizations.publisher?(organization, admin)

      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      assert Organizations.publisher?(organization, owner)
      # …and the grant does not cost them anything they already had.
      assert Organizations.owner?(organization, owner)
    end

    test "set_roles adds, removes and leaves the rest alone" do
      {organization, owner} = active_organization()
      member = insert(:activated_user)

      assert {:ok, ["admin", "publisher"]} =
               Organizations.set_roles(organization, member, ["publisher", "admin"], owner)

      granted_at =
        Repo.get_by!(OrganizationRole,
          organization_id: organization.id,
          user_id: member.id,
          role: "admin"
        )

      # Swapping publisher for recruiter must not disturb the untouched admin row.
      assert {:ok, ["admin", "recruiter"]} =
               Organizations.set_roles(organization, member, ["admin", "recruiter"], owner)

      assert Repo.get(OrganizationRole, granted_at.id).inserted_at == granted_at.inserted_at

      assert {:ok, []} = Organizations.set_roles(organization, member, [], owner)
      assert Organizations.roles_of(organization, member) == []
    end

    test "the last owner cannot be removed or demoted" do
      {organization, owner} = active_organization()

      owner_role =
        Repo.get_by(OrganizationRole, organization_id: organization.id, user_id: owner.id)

      assert {:error, :last_owner} = Organizations.remove_role(owner_role)

      assert {:error, :last_owner} =
               Organizations.set_roles(organization, owner, ["admin"], owner)

      assert {:error, :last_owner} = Organizations.set_roles(organization, owner, [], owner)

      # Holding another role beside owner does not weaken the guard.
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      assert {:error, :last_owner} =
               Organizations.set_roles(organization, owner, ["publisher"], owner)

      # A second owner lifts it.
      other = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, other, "owner", owner)
      assert {:ok, ["admin"]} = Organizations.set_roles(organization, owner, ["admin"], owner)
    end

    test "list_team gives one entry per member with every role they hold" do
      {organization, owner} = active_organization()
      member = insert(:activated_user)
      {:ok, _} = Organizations.set_roles(organization, member, ["recruiter", "publisher"], owner)

      assert [%{user: first, roles: ["owner"]}, %{user: second, roles: roles}] =
               Organizations.list_team(organization)

      assert first.id == owner.id
      assert second.id == member.id
      assert roles == ["publisher", "recruiter"]
    end

    test "roles_of answers with a ranked list, and the permission predicates read it" do
      {organization, owner} = active_organization()
      recruiter = insert(:activated_user)
      stranger = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, recruiter, "recruiter", owner)

      assert Organizations.roles_of(organization, owner) == ["owner"]
      assert Organizations.roles_of(organization, recruiter) == ["recruiter"]
      assert Organizations.roles_of(organization, stranger) == []
      assert Organizations.roles_of(organization, nil) == []

      assert Organizations.owner?(organization, owner)
      refute Organizations.owner?(organization, recruiter)
      assert Organizations.can_edit_page?(organization, owner)
      refute Organizations.can_edit_page?(organization, recruiter)
      refute Organizations.can_edit_page?(organization, stranger)
    end

    test "member_organizations pairs each page with the member's ranked roles" do
      {organization, owner} = active_organization()

      assert [{listed, ["owner"]}] = Organizations.member_organizations(owner)
      assert listed.id == organization.id
    end

    test "list_roles orders owner, admin, recruiter" do
      {organization, owner} = active_organization()
      r = insert(:activated_user)
      a = insert(:activated_user)
      {:ok, _} = Organizations.add_role(organization, r, "recruiter", owner)
      {:ok, _} = Organizations.add_role(organization, a, "admin", owner)

      assert Enum.map(Organizations.list_roles(organization), & &1.role) == [
               "owner",
               "admin",
               "recruiter"
             ]
    end
  end

  describe "domains" do
    test "add a second domain, verify it, and pick a primary" do
      {organization, _owner} = active_organization()

      assert {:ok, second} = Organizations.add_domain(organization, "https://acme.de", "dns")
      refute second.primary?
      refute second.verified_at

      stub_dns(second.verification_token)
      {:ok, _organization} = Organizations.check_domain(organization, second)
      second = Organizations.get_domain(organization, second.id)
      assert second.verified_at

      assert length(Organizations.verified_domains(organization)) == 2

      # Make the new domain primary; the badge follows.
      {:ok, promoted} = Organizations.set_primary_domain(organization, second)
      assert promoted.primary?
      assert Organizations.primary_domain(organization).domain == "acme.de"
    end

    test "an unverified domain cannot be made primary" do
      {organization, _owner} = active_organization()
      {:ok, second} = Organizations.add_domain(organization, "https://acme.de", "dns")
      assert {:error, :not_verified} = Organizations.set_primary_domain(organization, second)
    end

    test "a domain already claimed elsewhere is refused" do
      {organization_a, _} = active_organization()

      {organization_b, _} =
        active_organization(%{"name" => "Beta AG", "website_url" => "https://beta.example"})

      taken = Organizations.primary_domain(organization_b).domain

      assert {:error, :domain_taken} =
               Organizations.add_domain(organization_a, "https://#{taken}", "dns")
    end

    test "the last verified domain cannot be removed; removing the primary auto-promotes" do
      {organization, _owner} = active_organization()
      primary = Organizations.primary_domain(organization)

      assert {:error, :last_domain} = Organizations.remove_domain(organization, primary)

      {:ok, second} = Organizations.add_domain(organization, "https://acme.de", "dns")
      stub_dns(second.verification_token)
      {:ok, _} = Organizations.check_domain(organization, second)

      # Now the primary can go; the other verified domain becomes primary.
      {:ok, _} = Organizations.remove_domain(organization, primary)
      assert Organizations.primary_domain(organization).domain == "acme.de"
      assert length(Organizations.verified_domains(organization)) == 1
    end
  end

  describe "aliases" do
    test "add and list aliases; the directory finds an organization under an alias" do
      {organization, _owner} = active_organization()

      {:ok, brand} = Organizations.add_alias(organization, "AcmeCorp", "brand")
      assert brand.kind == "brand"
      assert Enum.map(Organizations.list_aliases(organization), & &1.name) == ["AcmeCorp"]

      page = Organizations.directory_page(search: "AcmeCorp")
      assert Enum.any?(page.entries, &(&1.id == organization.id))
    end

    test "renaming appends the old name as a former alias and keeps the slug" do
      {organization, _owner} = active_organization()
      slug = organization.slug

      {:ok, renamed} =
        Organizations.update_organization(organization, %{"name" => "Acme Holding GmbH"})

      assert renamed.slug == slug
      assert renamed.name == "Acme Holding GmbH"

      former = Organizations.list_aliases(renamed)
      assert Enum.any?(former, &(&1.name == "Acme GmbH" and &1.kind == "former"))
    end

    test "an alias equal to another verified organization's name is flagged for the admin queue" do
      {organization_a, _} = active_organization()

      {_organization_b, _} =
        active_organization(%{"name" => "Globex SE", "website_url" => "https://globex.example"})

      assert {:ok, flagged} = Organizations.add_alias(organization_a, "Globex SE", "brand")
      assert flagged.flagged_at
      assert Organizations.flagged_aliases_count() == 1

      # A harmless, unique alias is not flagged.
      {:ok, fine} = Organizations.add_alias(organization_a, "Totally Unique Name 4711", "brand")
      refute fine.flagged_at
    end
  end
end
