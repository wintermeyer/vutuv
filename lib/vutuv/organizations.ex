defmodule Vutuv.Organizations do
  @moduledoc """
  Verified organization pages (issue #929). An organization page can only exist once a
  member proved control of its web domain, so this context is organised around
  that trust model: a claim creates a `pending` organization plus an unverified
  primary `OrganizationDomain`; a successful proof (`Vutuv.Organizations.Verification`)
  flips it to `active` and stamps `verified_at`. DNS / well-known domains are
  re-checked periodically with a grace window before losing verified status.

  Engagement (like + bookmark) reuses `Vutuv.Engagement`; visibility, roles and
  the public directory live here too. Moderation freeze is applied by
  `Vutuv.Moderation` (which sets `organizations.frozen_at`); this context reads it
  in `organization_visible_to?/2`.
  """

  import Ecto.Query, warn: false
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1, account_hidden_row: 1]
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [escape_like: 1, normalize_search: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Engagement
  alias Vutuv.Handles
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationBookmark
  alias Vutuv.Organizations.OrganizationDomain
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Organizations.OrganizationLike
  alias Vutuv.Organizations.OrganizationName
  alias Vutuv.Organizations.OrganizationRole
  alias Vutuv.Organizations.Verification
  alias Vutuv.Pages
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.SlugHelpers

  # Slugs that would shadow a /organizations/<word> route.
  @reserved_slugs ~w(new)
  @directory_per_page 24
  @people_per_page 24
  # Domain-ownership proofs (a DNS TXT record / a static well-known file) almost
  # never change once set, so a weekly re-check is plenty; the hourly sweeper
  # tick just spreads these checks out rather than bursting them.
  @recheck_interval_hours 24 * 7
  @grace_days 7

  @doc """
  The canonical URL path of an organization page: its opt-in root handle when claimed
  (`/:username`, issue #941), otherwise `/organizations/:slug`. The one definition
  shared by the profile's work-experience link (issue #931), the agent docs and
  the sitemap, so a link never points at a non-canonical URL.
  """
  def canonical_path(%Organization{username: username}) when is_binary(username),
    do: "/" <> username

  def canonical_path(%Organization{slug: slug}), do: "/organizations/#{slug}"

  # --- fetch ------------------------------------------------------------------

  def get_organization(id), do: Repo.get(Organization, id)
  def get_organization!(id), do: Repo.get!(Organization, id)

  def get_organization_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Organization, slug: slug)

  def get_organization_by_slug(_), do: nil

  @doc "Fetches an organization by its opt-in root handle (issue #941), or nil."
  def get_organization_by_username(username) when is_binary(username),
    do: Repo.get_by(Organization, username: username)

  def get_organization_by_username(_), do: nil

  @doc """
  Fetches an organization by its root handle (issue #941) if `viewer` may see it, the
  handle-namespace twin of `fetch_visible_organization/2`. Returns
  `{:error, :not_found}` for an unknown handle or a page hidden from `viewer`.
  """
  def fetch_visible_organization_by_username(username, viewer) do
    case get_organization_by_username(username) do
      nil ->
        {:error, :not_found}

      organization ->
        if organization_visible_to?(organization, viewer),
          do: {:ok, organization},
          else: {:error, :not_found}
    end
  end

  @doc """
  Fetches an active, non-frozen organization by slug for a public viewer, or the
  page for an owner/admin who may see it while `pending`/`frozen`. Returns
  `{:error, :not_found}` otherwise.
  """
  def fetch_visible_organization(slug, viewer) do
    case get_organization_by_slug(slug) do
      nil ->
        {:error, :not_found}

      organization ->
        if organization_visible_to?(organization, viewer),
          do: {:ok, organization},
          else: {:error, :not_found}
    end
  end

  @doc "Whether `viewer` may see `organization` at all (public active page, or owner/admin)."
  def organization_visible_to?(%Organization{} = organization, viewer) do
    public_visible?(organization) or can_manage?(organization, viewer) or admin?(viewer)
  end

  @doc "Whether `organization` is on the public site (active and not frozen)."
  def public_visible?(%Organization{status: "active", frozen_at: nil}), do: true
  def public_visible?(_), do: false

  @doc "Whether the page appears in machine channels (sitemap, JSON-LD): active + seo?."
  def indexable?(%Organization{seo?: true} = organization), do: public_visible?(organization)
  def indexable?(_), do: false

  @doc "Whether the agent-format siblings (.md/.txt/.json/.xml) are served: active + geo?."
  def agent_visible?(%Organization{geo?: true} = organization), do: public_visible?(organization)
  def agent_visible?(_), do: false

  # --- roles ------------------------------------------------------------------
  #
  # Powers (issue #930): owner = roles + domains + page + job postings; admin =
  # page + job postings; recruiter = job postings only. Every role is a
  # proof-derived power, not an employment claim.

  @doc """
  Whether `user` is organization staff (creator or any role holder). This is the
  *visibility* predicate — a recruiter still sees a pending/frozen page — not
  the edit predicate; use `can_edit_page?/2` / `owner?/2` for writes.
  """
  def can_manage?(%Organization{} = organization, %User{} = user) do
    organization.created_by_user_id == user.id or role_holder?(organization.id, user.id)
  end

  def can_manage?(_, _), do: false

  @doc ~S|The `user`'s role on `organization` ("owner"/"admin"/"recruiter"), or nil.|
  def role_of(%Organization{id: id}, %User{id: user_id}) do
    Repo.one(
      from(r in OrganizationRole,
        where: r.organization_id == ^id and r.user_id == ^user_id,
        select: r.role
      )
    )
  end

  def role_of(_, _), do: nil

  @doc "Whether `user` is an owner of `organization` (manage roles + domains)."
  def owner?(%Organization{} = organization, %User{} = user),
    do: role_of(organization, user) == "owner"

  def owner?(_, _), do: false

  @doc "Whether `user` may edit the organization page + aliases (owner or admin)."
  def can_edit_page?(%Organization{} = organization, %User{} = user),
    do: role_of(organization, user) in ["owner", "admin"]

  def can_edit_page?(_, _), do: false

  @doc "Whether `user` may manage the roster (owner only)."
  def can_manage_roles?(organization, user), do: owner?(organization, user)

  @doc "Whether `user` may manage domains (owner only)."
  def can_manage_domains?(organization, user), do: owner?(organization, user)

  @doc """
  The active, non-frozen organizations `user` may post a job for (holds any role
  or created the page). Powers the job-posting editor's attribution select.
  """
  def postable_organizations(%User{id: user_id}) do
    Repo.all(
      from(o in Organization,
        left_join: r in OrganizationRole,
        on: r.organization_id == o.id and r.user_id == ^user_id,
        where:
          organization_public_row(o) and
            (o.created_by_user_id == ^user_id or not is_nil(r.id)),
        distinct: true,
        order_by: [asc: o.name]
      )
    )
  end

  @doc """
  Every organization the member helps run, as `{organization, role}` pairs
  ordered by name. Covers each page the member holds any role on (owner / admin
  / recruiter) — the claim wizard always makes the creator an `owner`, so a
  member's own pages are included too. **Pending** pages (still finishing domain
  verification) and **frozen** ones are kept so the member can act on them;
  **archived** pages are dropped. Powers the member's "Your organizations" page
  at `/settings/organizations` (distinct from `postable_organizations/1`, which
  is the active-only job-posting attribution set).
  """
  def member_organizations(%User{id: user_id}) do
    Repo.all(
      from(r in OrganizationRole,
        join: o in Organization,
        on: o.id == r.organization_id,
        where: r.user_id == ^user_id and o.status != "archived",
        order_by: [asc: fragment("lower(?)", o.name)],
        select: {o, r.role}
      )
    )
  end

  @doc "An organization's roles, owner → admin → recruiter, each oldest first, user preloaded."
  def list_roles(%Organization{id: id}) do
    Repo.all(from(r in OrganizationRole, where: r.organization_id == ^id, preload: [:user]))
    |> Enum.sort_by(&{role_rank(&1.role), &1.id})
  end

  defp role_rank("owner"), do: 0
  defp role_rank("admin"), do: 1
  defp role_rank("recruiter"), do: 2
  defp role_rank(_), do: 3

  @doc """
  Up to six member suggestions for the roles typeahead, matched by `@handle` or
  name, excluding the ids in `exclude` (the current role holders). Returns `[]`
  for a term shorter than two characters.
  """
  def suggest_members(term, exclude \\ []) do
    trimmed = term |> to_string() |> String.trim() |> String.trim_leading("@")

    if String.length(trimmed) < 2 do
      []
    else
      like = "%" <> escape_like(trimmed) <> "%"

      Repo.all(
        from(u in User,
          where:
            u.id not in ^exclude and account_confirmed_row(u) and not account_hidden_row(u) and
              (ilike(u.username, ^like) or ilike(u.first_name, ^like) or ilike(u.last_name, ^like)),
          order_by: [asc: u.username],
          limit: 6
        )
      )
    end
  end

  @doc "Fetches one role row scoped to an organization (owner-management actions)."
  def get_role(%Organization{id: id}, role_id) do
    Repo.one(
      from(r in OrganizationRole,
        where: r.organization_id == ^id and r.id == ^role_id,
        preload: [:user]
      )
    )
  end

  @doc """
  Grants `user` a role on `organization`. Notifies the member (the derived
  notification feed picks up the row; a live push updates the badge). Returns
  `{:ok, role}`, `{:error, :already_member}` when they already hold a role, or
  `{:error, changeset}`.
  """
  def add_role(%Organization{} = organization, %User{} = user, role, %User{} = granted_by)
      when role in ~w(owner admin recruiter) do
    %OrganizationRole{}
    |> OrganizationRole.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role,
      granted_by_user_id: granted_by.id
    })
    |> Repo.insert()
    |> case do
      {:ok, role_row} ->
        Vutuv.Activity.notify_organization_role(user.id, granted_by, organization, role)
        {:ok, role_row}

      {:error, %{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :organization_id) or Keyword.has_key?(errors, :user_id),
          do: {:error, :already_member},
          else: {:error, changeset}
    end
  end

  @doc """
  Changes an existing role. Refuses to demote the last owner (keeps the
  ≥ 1-owner invariant). Notifies the member of an upgrade/downgrade.
  """
  def update_role(%OrganizationRole{} = role_row, new_role, %User{} = actor)
      when new_role in ~w(owner admin recruiter) do
    cond do
      role_row.role == new_role ->
        {:ok, role_row}

      role_row.role == "owner" and new_role != "owner" ->
        # Demoting an owner races with a concurrent demotion of a DIFFERENT owner:
        # both could read owner_count > 1 and commit, orphaning the org with zero
        # owners (write skew). Serialize the check and the write under a row lock.
        guard_last_owner(role_row.organization_id, fn ->
          apply_role_change(role_row, new_role, actor)
        end)

      true ->
        apply_role_change(role_row, new_role, actor)
    end
  end

  defp apply_role_change(role_row, new_role, actor) do
    with {:ok, updated} <- role_row |> Ecto.Changeset.change(role: new_role) |> Repo.update() do
      organization = get_organization!(updated.organization_id)
      Vutuv.Activity.notify_organization_role(updated.user_id, actor, organization, new_role)
      {:ok, updated}
    end
  end

  @doc """
  Removes a role (an owner removing a member, or a member leaving). Refuses to
  remove the last owner (an organization always keeps ≥ 1 owner).
  """
  def remove_role(%OrganizationRole{role: "owner"} = role_row) do
    guard_last_owner(role_row.organization_id, fn -> Repo.delete(role_row) end)
  end

  def remove_role(%OrganizationRole{} = role_row), do: Repo.delete(role_row)

  # Runs `fun` (an owner demotion / removal) only if the org would keep >= 1
  # owner, with the owner rows locked FOR UPDATE for the whole transaction so two
  # concurrent last-owner checks can't both pass. Returns `{:ok, result}`,
  # `{:error, :last_owner}`, or `fun`'s own `{:error, _}`.
  defp guard_last_owner(organization_id, fun) do
    Repo.transaction(fn ->
      if last_owner_locked?(organization_id),
        do: Repo.rollback(:last_owner),
        else: run_or_rollback(fun)
    end)
  end

  # Locks the org's owner rows FOR UPDATE (so a concurrent demotion blocks and
  # re-reads) and reports whether removing one would drop below one owner.
  defp last_owner_locked?(organization_id) do
    owners =
      Repo.all(
        from(r in OrganizationRole,
          where: r.organization_id == ^organization_id and r.role == "owner",
          lock: "FOR UPDATE"
        )
      )

    length(owners) <= 1
  end

  defp run_or_rollback(fun) do
    case fun.() do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp role_holder?(organization_id, user_id) do
    Repo.exists?(
      from(r in OrganizationRole,
        where: r.organization_id == ^organization_id and r.user_id == ^user_id
      )
    )
  end

  defp admin?(%User{admin?: true}), do: true
  defp admin?(_), do: false

  # --- claim + create ---------------------------------------------------------

  @doc "A blank create changeset for the claim wizard form."
  def change_new_organization(attrs \\ %{}),
    do: Organization.create_changeset(%Organization{}, attrs)

  @doc "An edit changeset for the owner form."
  def change_organization(%Organization{} = organization, attrs \\ %{}),
    do: Organization.edit_changeset(organization, attrs)

  @doc """
  Creates a `pending` organization from the claim wizard: the organization + an owner
  role + an unverified primary domain (derived from the website URL, using the
  chosen `method`). Returns `{:ok, %{organization: c, domain: d}}`,
  `{:error, :domain_taken}` when the domain already belongs to another organization,
  or `{:error, changeset}`.
  """
  def create_pending_organization(%User{} = user, attrs, method)
      when method in ~w(dns well_known) do
    changeset =
      %Organization{created_by_user_id: user.id, status: "pending"}
      |> Organization.create_changeset(attrs)
      |> require_website()

    if changeset.valid? do
      do_create_pending(user, changeset, method)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp require_website(changeset) do
    case Ecto.Changeset.get_field(changeset, :website_url) do
      nil -> Ecto.Changeset.add_error(changeset, :website_url, "is required to verify the domain")
      _ -> changeset
    end
  end

  defp do_create_pending(user, changeset, method) do
    name = Ecto.Changeset.get_field(changeset, :name)

    slug =
      SlugHelpers.gen_slug_unique(
        String.slice(name, 0, 120),
        Organization,
        :slug,
        @reserved_slugs
      )

    host = OrganizationDomain.normalize(Ecto.Changeset.get_field(changeset, :website_url))
    token = Verification.gen_token()

    organization_changeset =
      changeset
      |> Ecto.Changeset.put_change(:slug, slug)
      |> Ecto.Changeset.validate_length(:slug, max: 255)
      |> Ecto.Changeset.unique_constraint(:slug)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, organization_changeset)
    |> Ecto.Multi.insert(:role, fn %{organization: organization} ->
      OrganizationRole.changeset(%OrganizationRole{}, %{
        organization_id: organization.id,
        user_id: user.id,
        role: "owner",
        granted_by_user_id: user.id
      })
    end)
    |> Ecto.Multi.insert(:domain, fn %{organization: organization} ->
      OrganizationDomain.changeset(%OrganizationDomain{}, %{
        organization_id: organization.id,
        domain: host,
        primary?: true,
        method: method,
        verification_token: token
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: _, domain: _} = result} -> {:ok, result}
      {:error, :domain, _changeset, _} -> {:error, :domain_taken}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # --- owner edit -------------------------------------------------------------

  @doc """
  Applies the owner/admin edit form; keeps the slug stable (renames keep the
  URL). A rename auto-appends the old name as a `former` alias, so the rename
  history is data, not a log file (issue #930).
  """
  def update_organization(%Organization{} = organization, attrs) do
    changeset = Organization.edit_changeset(organization, attrs)
    old_name = organization.name

    Ecto.Multi.new()
    |> Ecto.Multi.update(:organization, changeset)
    |> Ecto.Multi.run(:former_alias, fn _repo, %{organization: updated} ->
      if updated.name != old_name, do: record_former_alias(updated, old_name), else: {:ok, nil}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: updated}} -> {:ok, updated}
      {:error, :organization, changeset, _} -> {:error, changeset}
      {:error, _step, _reason, _} -> {:error, %{changeset | action: :update}}
    end
  end

  @doc """
  Claims (or changes) the organization's opt-in root handle (issue #941): validates
  the grammar, then upserts the `handles` registry row in the same transaction,
  so a handle already held by a member or another organization loses on the unique
  index and comes back as a `:username` changeset error. Owner-only — the caller
  gates on `owner?/2`.
  """
  # Only a verified, live page earns a global root handle. A pending (never
  # domain-proven) org must not lock a handle it can't prove it controls — that
  # is cheap, repeatable namespace squatting against the registry's UNIQUE(value).
  def claim_handle(%Organization{status: status}, _attrs) when status != "active",
    do: {:error, :not_verified}

  def claim_handle(%Organization{} = organization, attrs) do
    changeset = Organization.handle_changeset(organization, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:organization, changeset)
    |> Ecto.Multi.run(:handle, fn repo, %{organization: updated} ->
      Handles.put_organization_handle(repo, updated)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: updated}} ->
        {:ok, updated}

      {:error, :organization, changeset, _} ->
        {:error, changeset}

      {:error, :handle, _handle_changeset, _} ->
        {:error,
         changeset
         |> Ecto.Changeset.add_error(:username, "has already been taken")
         |> Map.put(:action, :update)}
    end
  end

  # --- verification -----------------------------------------------------------

  @doc "All of an organization's domains, primary first. An organization has very few."
  def list_domains(%Organization{id: id}) do
    Repo.all(
      from(d in OrganizationDomain,
        where: d.organization_id == ^id,
        order_by: [desc: d.primary?, asc: d.inserted_at]
      )
    )
  end

  @doc "The primary (claim) domain of an organization."
  def primary_domain(%Organization{} = organization),
    do: Enum.find(list_domains(organization), & &1.primary?)

  @doc "An organization's currently verified domains, primary first."
  def verified_domains(%Organization{} = organization),
    do: Enum.filter(list_domains(organization), & &1.verified_at)

  @doc """
  Adds a second (or further) domain to an organization (issue #930): a non-primary,
  not-yet-verified `OrganizationDomain` derived from `url`, using `method`. The owner
  finishes it with the #929 verification wizard on the domains page (which flips
  it to verified without touching the organization status). Returns `{:ok, domain}`,
  `{:error, :domain_taken}` when the host already belongs to an organization, or
  `{:error, changeset}`.
  """
  def add_domain(%Organization{} = organization, url, method) when method in ~w(dns well_known) do
    host = OrganizationDomain.normalize(url)

    %OrganizationDomain{}
    |> OrganizationDomain.changeset(%{
      organization_id: organization.id,
      domain: host,
      primary?: false,
      method: method,
      verification_token: Verification.gen_token()
    })
    |> Repo.insert()
    |> case do
      {:ok, domain} -> {:ok, domain}
      {:error, changeset} -> {:error, domain_error(changeset)}
    end
  end

  # A unique-constraint hit on the host means it belongs to another organization; any
  # other error is a plain validation failure (returned as the changeset).
  defp domain_error(changeset) do
    taken? =
      Enum.any?(changeset.errors, fn
        {:domain, {_msg, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    if taken?, do: :domain_taken, else: changeset
  end

  @doc "Fetches one domain row scoped to an organization (owner-management actions)."
  def get_domain(%Organization{id: id}, domain_id) do
    Repo.one(
      from(d in OrganizationDomain, where: d.organization_id == ^id and d.id == ^domain_id)
    )
  end

  @doc """
  Removes a domain. Refuses to remove the organization's **last verified** domain
  (every active organization keeps ≥ 1, like the last owner). Removing the primary
  auto-promotes the oldest remaining verified domain, so the badge follows.
  """
  def remove_domain(%Organization{} = organization, %OrganizationDomain{} = domain) do
    if domain.verified_at && verified_domain_count(organization.id) <= 1 do
      {:error, :last_domain}
    else
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.delete!(domain)
          if domain.primary?, do: promote_new_primary(organization.id)
        end)

      {:ok, organization}
    end
  end

  # Makes the oldest remaining verified domain the new primary.
  defp promote_new_primary(organization_id) do
    Repo.one(
      from(d in OrganizationDomain,
        where: d.organization_id == ^organization_id and not is_nil(d.verified_at),
        order_by: [asc: d.inserted_at],
        limit: 1
      )
    )
    |> case do
      nil -> :ok
      domain -> Repo.update!(Ecto.Changeset.change(domain, primary?: true))
    end
  end

  @doc """
  Picks the domain shown in the \"Verifiziert über …\" badge. Only a verified
  domain can be primary. Flips atomically (old primary off, then new on) so the
  one-primary partial unique index is never violated mid-write.
  """
  def set_primary_domain(%Organization{} = organization, %OrganizationDomain{} = domain) do
    cond do
      is_nil(domain.verified_at) ->
        {:error, :not_verified}

      domain.primary? ->
        {:ok, domain}

      true ->
        {:ok, updated} =
          Repo.transaction(fn ->
            Repo.update_all(
              from(d in OrganizationDomain,
                where: d.organization_id == ^organization.id and d.primary?
              ),
              set: [primary?: false]
            )

            Repo.update!(Ecto.Changeset.change(domain, primary?: true))
          end)

        {:ok, updated}
    end
  end

  defp verified_domain_count(organization_id) do
    Repo.aggregate(
      from(d in OrganizationDomain,
        where: d.organization_id == ^organization_id and not is_nil(d.verified_at)
      ),
      :count,
      :id
    )
  end

  @doc "The TXT value a member must publish for DNS verification."
  def dns_txt_value(%OrganizationDomain{verification_token: token}),
    do: Verification.dns_txt_value(token)

  @doc """
  The CNAME-safe alternate name (`_vutuv.<domain>`) the DNS TXT record may also
  live at, for a domain that is itself a CNAME.
  """
  def dns_challenge_name(%OrganizationDomain{domain: host}),
    do: Verification.dns_challenge_name(host)

  @doc "The well-known file URL and content for the `well_known` method."
  def well_known_url(%OrganizationDomain{domain: host}), do: Verification.well_known_url(host)
  def well_known_content(%OrganizationDomain{verification_token: token}), do: token

  @doc "Whether domain verification (DNS TXT + well-known) is enabled for this install."
  def verification_enabled?, do: Verification.enabled?()

  @doc "Runs the domain's current verification method; on success activates the organization."
  def verify_domain(%Organization{} = organization, %OrganizationDomain{method: "dns"} = domain),
    do: verify_dns(organization, domain)

  def verify_domain(
        %Organization{} = organization,
        %OrganizationDomain{method: "well_known"} = domain
      ),
      do: verify_well_known(organization, domain)

  @doc "Switches a pending domain between the DNS and well-known methods (same token)."
  def set_domain_method(%OrganizationDomain{} = domain, method)
      when method in ~w(dns well_known) do
    domain |> Ecto.Changeset.change(method: method) |> Repo.update()
  end

  @doc "Verifies a DNS domain; on success activates the organization."
  def verify_dns(%Organization{} = organization, %OrganizationDomain{method: "dns"} = domain),
    do: do_verify(organization, domain, &Verification.dns_verified?/2)

  @doc "Verifies a well-known-file domain; on success activates the organization."
  def verify_well_known(
        %Organization{} = organization,
        %OrganizationDomain{method: "well_known"} = domain
      ),
      do: do_verify(organization, domain, &Verification.well_known_verified?/2)

  defp do_verify(%Organization{} = organization, %OrganizationDomain{} = domain, check) do
    if verification_enabled?() and check.(domain.domain, domain.verification_token) do
      activate(organization, domain)
    else
      {:error, :not_found}
    end
  end

  # Flips a pending organization to active off a freshly verified domain, stamps
  # verified_at once, and alerts the operator on first verification.
  defp activate(%Organization{} = organization, %OrganizationDomain{} = domain) do
    now = now()
    first? = is_nil(organization.verified_at)

    organization_changeset =
      organization
      |> Organization.status_changeset("active")
      |> then(fn cs ->
        if first?, do: Ecto.Changeset.put_change(cs, :verified_at, now), else: cs
      end)

    {:ok, %{organization: organization, domain: domain}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :domain,
        OrganizationDomain.check_changeset(domain, %{
          verified_at: now,
          last_checked_at: now,
          grace_deadline_at: nil
        })
      )
      |> Ecto.Multi.update(:organization, organization_changeset)
      |> Repo.transaction()

    if first? do
      organization
      |> Emailer.organization_verified_notice(domain)
      |> Emailer.deliver()
    end

    {:ok, organization}
  end

  # --- periodic re-check ------------------------------------------------------

  @doc "DNS / well-known domains whose last check is older than the interval."
  def domains_due_for_recheck(now \\ NaiveDateTime.utc_now()) do
    cutoff = NaiveDateTime.add(now, -@recheck_interval_hours * 3600)

    Repo.all(
      from(d in OrganizationDomain,
        where:
          d.method in ["dns", "well_known"] and not is_nil(d.verified_at) and
            (is_nil(d.last_checked_at) or d.last_checked_at < ^cutoff)
      )
    )
  end

  @doc """
  Re-checks all due DNS / well-known domains (called by the sweeper). No-op when
  network verification is disabled. Returns the count of domains that lost
  verified status this run.
  """
  def recheck_due_domains do
    if verification_enabled?() do
      # Each check does one blocking DNS / HTTP call (no DB connection held
      # during it), so run them with bounded concurrency instead of summing
      # every domain's network latency serially.
      domains_due_for_recheck()
      |> Task.async_stream(&recheck_domain/1,
        max_concurrency: 10,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.count(fn {:ok, outcome} -> outcome in [:demoted_domain, :demoted_organization] end)
    else
      0
    end
  end

  @doc """
  Re-checks one domain. On success refreshes `last_checked_at` and clears any
  grace window. On failure starts a grace window, waits it out, then demotes the
  domain (and the organization, if it was its last verified domain, alerting the
  operator). Returns an outcome atom.
  """
  def recheck_domain(%OrganizationDomain{} = domain) do
    now = now()

    verified? =
      case domain.method do
        "dns" ->
          Verification.dns_verified?(domain.domain, domain.verification_token)

        "well_known" ->
          Verification.well_known_verified?(domain.domain, domain.verification_token)

        _ ->
          true
      end

    if verified? do
      domain
      |> OrganizationDomain.check_changeset(%{last_checked_at: now, grace_deadline_at: nil})
      |> Repo.update()

      :ok
    else
      handle_recheck_failure(domain, now)
    end
  end

  defp handle_recheck_failure(domain, now) do
    cond do
      is_nil(domain.grace_deadline_at) ->
        deadline = NaiveDateTime.add(now, @grace_days * 86_400)

        domain
        |> OrganizationDomain.check_changeset(%{
          last_checked_at: now,
          grace_deadline_at: deadline
        })
        |> Repo.update()

        :grace_started

      NaiveDateTime.compare(now, domain.grace_deadline_at) == :lt ->
        domain
        |> OrganizationDomain.check_changeset(%{last_checked_at: now})
        |> Repo.update()

        :in_grace

      true ->
        demote_domain(domain, now)
    end
  end

  defp demote_domain(domain, now) do
    was_primary = domain.primary?

    changeset =
      domain
      |> OrganizationDomain.check_changeset(%{
        verified_at: nil,
        last_checked_at: now,
        grace_deadline_at: nil
      })

    # check_changeset can't cast primary?, so clear it here (put_change bypasses
    # cast): a demoted primary must not keep a false "verified via <domain>"
    # badge. Clearing it in the same write also frees the one-primary partial
    # unique index before we promote a replacement below.
    changeset =
      if was_primary, do: Ecto.Changeset.put_change(changeset, :primary?, false), else: changeset

    {:ok, domain} = Repo.update(changeset)

    organization = get_organization!(domain.organization_id)

    if verified_domain_count(organization.id) == 0 do
      {:ok, organization} =
        organization |> Organization.status_changeset("pending") |> Repo.update()

      organization
      |> Emailer.organization_unverified_notice(domain)
      |> Emailer.deliver()

      :demoted_organization
    else
      # A non-last domain was dropped: the page stays verified via its others,
      # but the operator is still alerted (issue #930). If the demoted domain was
      # the primary, move the badge to a still-verified one.
      if was_primary, do: promote_new_primary(organization.id)

      organization
      |> Emailer.organization_domain_dropped_notice(domain)
      |> Emailer.deliver()

      :demoted_domain
    end
  end

  # --- engagement (like + bookmark) ------------------------------------------

  # The Engagement fabric config: the fk doubles as the payload id key, and
  # the two tuple names are pattern-matched by OrganizationLive.Show and
  # PostLive.Saved — a rename is a breaking contract change.
  @engagement_cfg %{
    fk: :organization_id,
    like_schema: OrganizationLike,
    topic_prefix: "organization",
    counters_msg: :organization_counters,
    changed_msg: :organization_engagement_changed
  }

  def like_organization(%User{} = user, %Organization{} = organization),
    do: Engagement.engage(OrganizationLike, :like, user.id, organization.id, @engagement_cfg)

  def unlike_organization(%User{} = user, %Organization{} = organization),
    do: Engagement.disengage(OrganizationLike, :like, user.id, organization.id, @engagement_cfg)

  def bookmark_organization(%User{} = user, %Organization{} = organization),
    do:
      Engagement.engage(
        OrganizationBookmark,
        :bookmark,
        user.id,
        organization.id,
        @engagement_cfg
      )

  def unbookmark_organization(%User{} = user, %Organization{} = organization),
    do:
      Engagement.disengage(
        OrganizationBookmark,
        :bookmark,
        user.id,
        organization.id,
        @engagement_cfg
      )

  @doc """
  Flips one engagement `kind` off its current state (the
  `%{liked?:, bookmarked?:}` map `organization_engagement/2` returns; nil
  reads as unengaged) — the jobs twin lives in `Vutuv.Jobs.toggle_engagement/4`.
  """
  def toggle_engagement(:like, user, organization, %{liked?: true}),
    do: unlike_organization(user, organization)

  def toggle_engagement(:like, user, organization, _), do: like_organization(user, organization)

  def toggle_engagement(:bookmark, user, organization, %{bookmarked?: true}),
    do: unbookmark_organization(user, organization)

  def toggle_engagement(:bookmark, user, organization, _),
    do: bookmark_organization(user, organization)

  @doc """
  Public like count plus the viewer's own `liked?`/`bookmarked?` flags for the
  action bar. An anonymous viewer gets `false` flags.
  """
  def organization_engagement(%Organization{id: organization_id}, viewer) do
    Engagement.subject_engagement(OrganizationBookmark, organization_id, viewer, @engagement_cfg)
  end

  @doc "Subscribes to an organization's live counter topic."
  def subscribe(organization_id), do: Engagement.subscribe(organization_id, @engagement_cfg)

  @doc """
  One page of the member's liked / bookmarked organizations for the `/bookmarks`
  saved-items hub, honoring its search (`name`/`city`) and sort. Returns
  `%{entries:, more?:, next_offset:}` (offset pagination), like the posts pages.
  """
  def saved_organizations_page(%User{id: user_id}, kind, opts) when kind in [:like, :bookmark] do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search = normalize_search(opts[:search])
    schema = if kind == :like, do: OrganizationLike, else: OrganizationBookmark

    query =
      from(c in Organization,
        join: e in ^schema,
        as: :engagement,
        on: e.organization_id == c.id,
        where: e.user_id == ^user_id and organization_public_row(c)
      )

    query = if search, do: name_or_city_ilike(query, search), else: query

    entries =
      query
      |> saved_order(opts[:sort])
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> select([c], c)
      |> Repo.all()

    Pages.offset_page(entries, limit, offset)
  end

  defp saved_order(query, :oldest), do: order_by(query, [engagement: e], asc: e.inserted_at)
  defp saved_order(query, :name), do: order_by(query, [c], asc: fragment("lower(?)", c.name))
  defp saved_order(query, _recent), do: order_by(query, [engagement: e], desc: e.inserted_at)

  # --- aliases (organization_names) ------------------------------------------------
  #
  # Alternative names an organization is findable under (issue #930): the directory and
  # admin search match names AND aliases. A collision with another verified
  # organization's name/alias is stored but flagged for the admin queue (no
  # user-facing warning — identical organization names are common and legitimate).

  @doc "An organization's alternative names, newest kind-grouped, for the edit + admin views."
  def list_aliases(%Organization{id: id}) do
    Repo.all(
      from(n in OrganizationName, where: n.organization_id == ^id, order_by: [asc: n.inserted_at])
    )
  end

  @doc "Fetches one alias row scoped to an organization (owner/admin edit)."
  def get_alias(%Organization{id: id}, alias_id) do
    Repo.one(from(n in OrganizationName, where: n.organization_id == ^id and n.id == ^alias_id))
  end

  @doc """
  Adds an alias (kind `alias`/`brand`/`abbreviation`; `former` is minted by a
  rename). Stored even on a collision, but stamped `flagged_at` for the admin
  queue when equal (case-insensitive) to another verified organization's name or
  alias. Returns `{:ok, organization_name}` or `{:error, changeset}` (a duplicate on
  this organization hits the unique index).
  """
  def add_alias(%Organization{} = organization, name, kind \\ "alias") do
    flagged_at = if alias_collision?(organization.id, name), do: now()

    %OrganizationName{}
    |> OrganizationName.changeset(%{
      organization_id: organization.id,
      name: name,
      kind: kind,
      flagged_at: flagged_at
    })
    |> Repo.insert()
  end

  @doc "Removes an alias."
  def remove_alias(%OrganizationName{} = organization_name), do: Repo.delete(organization_name)

  # Records the old name as a `former` alias on rename (idempotent — skips if the
  # name is already listed), flagging collisions like any other alias.
  defp record_former_alias(%Organization{} = organization, old_name) do
    if is_binary(old_name) and String.trim(old_name) != "" and
         not alias_exists?(organization.id, old_name) do
      add_alias(organization, old_name, "former")
    else
      {:ok, nil}
    end
  end

  defp downcase_name(name), do: name |> to_string() |> String.trim() |> String.downcase()

  defp alias_exists?(organization_id, name) do
    down = downcase_name(name)

    Repo.exists?(
      from(n in OrganizationName,
        where: n.organization_id == ^organization_id and fragment("lower(?)", n.name) == ^down
      )
    )
  end

  # Whether `name` equals (case-insensitive) another **verified** (active)
  # organization's name or any of its aliases. Deliberately NOT
  # `organization_public_row/1`: a frozen page keeps `status: "active"` and its
  # name stays taken while it is hidden.
  defp alias_collision?(organization_id, name) do
    down = downcase_name(name)

    name_hit? =
      Repo.exists?(
        from(c in Organization,
          where:
            c.id != ^organization_id and c.status == "active" and
              fragment("lower(?)", c.name) == ^down
        )
      )

    name_hit? or
      Repo.exists?(
        from(n in OrganizationName,
          join: c in Organization,
          on: c.id == n.organization_id,
          where:
            n.organization_id != ^organization_id and c.status == "active" and
              fragment("lower(?)", n.name) == ^down
        )
      )
  end

  @doc "How many aliases are flagged for the admin queue (a collision guardrail hit)."
  def flagged_aliases_count do
    Repo.aggregate(from(n in OrganizationName, where: not is_nil(n.flagged_at)), :count, :id)
  end

  @doc "All flagged aliases (newest first), each with its organization, for the admin queue."
  def list_flagged_aliases do
    Repo.all(
      from(n in OrganizationName,
        where: not is_nil(n.flagged_at),
        order_by: [desc: n.flagged_at],
        preload: [:organization]
      )
    )
  end

  @doc "Fetches one alias row by id for the admin queue, or nil."
  def get_alias(id), do: Vutuv.UUIDv7.with_cast(id, &Repo.get(OrganizationName, &1))

  @doc "Clears an alias's admin-queue flag (a human reviewed it and it is fine)."
  def clear_alias_flag(%OrganizationName{} = organization_name),
    do: organization_name |> Ecto.Changeset.change(flagged_at: nil) |> Repo.update()

  # --- work-experience linking (issue #931) -----------------------------------
  #
  # A member may optionally link a work experience to a verified organization page.
  # The link is a display convenience, not a badge — the employment claim stays
  # self-asserted. Only a **verified** (active, non-frozen) organization is ever a
  # link target, so a frozen/archived page silently reverts every linked
  # experience to plain text.

  @doc "Fetches an active, non-frozen organization by id (a linkable target), or nil."
  def get_active_organization(id) when is_binary(id) do
    Repo.one(from(c in Organization, where: c.id == ^id and organization_public_row(c)))
  end

  def get_active_organization(_), do: nil

  @doc """
  The verified organization a member's free-text organization would link to: an
  active, non-frozen organization whose **name or an alias equals** the trimmed text
  case-insensitively. Exact equality, not a substring — the editor only suggests
  a link when the whole employer name matches, so "Acme" never volunteers "Acme
  Foundation". Returns the `%Organization{}` or nil (a term under two characters, or
  no match, yields nil). When several verified organizations legitimately share a
  name the oldest wins, so the suggestion is deterministic.
  """
  def suggest_organization_for_org(name) do
    down = downcase_name(name)

    if String.length(down) < 2 do
      nil
    else
      Repo.one(
        from(c in Organization,
          where: organization_public_row(c),
          where:
            fragment("lower(?)", c.name) == ^down or
              fragment(
                "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND lower(cn.name) = ?)",
                c.id,
                ^down
              ),
          order_by: [asc: c.inserted_at],
          limit: 1
        )
      )
    end
  end

  @doc "The organization page's per-page size for its People section."
  def people_per_page, do: @people_per_page

  @doc """
  The number of members whose linked work experience is at `organization` and who are
  publicly listable (`Vutuv.Directory.indexable_users` semantics: confirmed, not
  search-opted-out, not moderation-hidden). The count the People section shows.
  """
  def organization_people_count(%Organization{id: id}) do
    people_base(id)
    |> select([_w, u], u.id)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc """
  One page of `organization`'s **People**: members whose linked work experience is at
  this organization. Current members (an ongoing linked role, no end date) lead, then
  past members, each group by name; offset-paginated like the saved-items hub.

  Each entry is `%{user:, title:, current?:}` where `title` is the linked role's
  title **exactly as the member wrote it** (their most recent role at the
  organization). Privacy is the member-directory gate (`indexable_users` semantics),
  so a member who opted out of public listing or is moderation-hidden never
  appears — the same set the agent-format people list carries. Returns
  `%{entries:, more?:, next_offset:}`.
  """
  def organization_people_page(%Organization{id: organization_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, @people_per_page)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      people_base(organization_id)
      |> select([w, u], %{user_id: u.id, current?: fragment("bool_or(? IS NULL)", w.end_year)})
      |> order_by([w, u], [
        {:desc, fragment("bool_or(? IS NULL)", w.end_year)},
        {:asc,
         fragment("lower(coalesce(nullif(trim(?), ''), ?, ''))", u.last_name, u.first_name)},
        {:asc, fragment("lower(coalesce(?, ''))", u.first_name)},
        {:asc, u.id}
      ])
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    page = Pages.offset_page(rows, limit, offset)

    ids = Enum.map(page.entries, & &1.user_id)
    users = ids |> load_people() |> Map.new(&{&1.id, &1})
    titles = representative_titles(organization_id, ids)

    entries =
      Enum.map(page.entries, fn row ->
        %{
          user: Map.fetch!(users, row.user_id),
          title: Map.get(titles, row.user_id),
          current?: row.current?
        }
      end)

    %{page | entries: entries}
  end

  # One row per listable member with a linked experience at the organization, grouped
  # so the current?/title aggregates collapse a member's several roles into one.
  defp people_base(organization_id) do
    from(w in WorkExperience,
      join: u in User,
      on: u.id == w.user_id,
      where:
        w.organization_id == ^organization_id and account_confirmed_row(u) and
          not u.noindex? and not account_hidden_row(u),
      group_by: u.id
    )
  end

  defp load_people(ids), do: Repo.all(from(u in User, where: u.id in ^ids))

  # The title each shown member is listed under: their most recent linked role at
  # the organization — an ongoing one wins, else the one with the latest end date.
  defp representative_titles(_organization_id, []), do: %{}

  defp representative_titles(organization_id, ids) do
    from(w in WorkExperience,
      where: w.organization_id == ^organization_id and w.user_id in ^ids,
      select: %{
        user_id: w.user_id,
        title: w.title,
        start_year: w.start_year,
        start_month: w.start_month,
        end_year: w.end_year,
        end_month: w.end_month
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, roles} -> {user_id, representative_title(roles)} end)
  end

  defp representative_title(roles) do
    chosen =
      case Enum.filter(roles, &is_nil(&1.end_year)) do
        [] ->
          Enum.max_by(
            roles,
            &{&1.end_year || 0, &1.end_month || 0, &1.start_year || 0, &1.start_month || 0}
          )

        ongoing ->
          Enum.max_by(ongoing, &{&1.start_year || 0, &1.start_month || 0})
      end

    chosen.title
  end

  # --- directory --------------------------------------------------------------

  @doc """
  A page of the public directory: active, non-frozen organizations, ordered by name,
  optionally filtered by a search over name AND city. Returns a map with
  `:entries`, `:page`, `:total_pages`, `:total`, `:per_page`.
  """
  def directory_page(opts \\ []) do
    search = normalize_search(opts[:search])
    query = directory_query(search)
    total = Repo.aggregate(query, :count, :id)
    total_pages = max(1, ceil(total / @directory_per_page))
    page = (opts[:page] || 1) |> max(1) |> min(total_pages)

    entries =
      query
      |> order_by([c], asc: fragment("lower(?)", c.name))
      |> limit(^@directory_per_page)
      |> offset(^((page - 1) * @directory_per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total,
      per_page: @directory_per_page
    }
  end

  defp directory_query(nil),
    do: from(c in Organization, where: organization_public_row(c))

  defp directory_query(term), do: name_or_city_ilike(directory_query(nil), term)

  # Case-insensitive match on name, city OR any alias, LIKE wildcards escaped.
  defp name_or_city_ilike(query, term) do
    pattern = "%" <> escape_like(term) <> "%"

    from(c in query,
      where:
        ilike(c.name, ^pattern) or ilike(c.city, ^pattern) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND cn.name ILIKE ?)",
            c.id,
            ^pattern
          )
    )
  end

  @doc """
  The active + non-frozen + seo? organization set: the one definition of "indexable"
  shared by the sitemap (mirrors how `Sitemap` delegates the member set to
  `Vutuv.Directory`, so the two can never drift).
  """
  def indexable_query do
    from(c in Organization, where: organization_public_row(c) and c.seo?)
  end

  # --- admin dashboard (issue #930) -------------------------------------------

  @admin_per_page 25

  @doc "Overview tile counts for /admin/organizations (live / pending / frozen)."
  def admin_overview_counts do
    Repo.one(
      from(c in Organization,
        select: %{
          active: filter(count(c.id), organization_public_row(c)),
          pending: filter(count(c.id), c.status == "pending"),
          frozen: filter(count(c.id), not is_nil(c.frozen_at))
        }
      )
    )
  end

  @doc """
  A page of the admin organization list: filtered by `:status`
  (`active`/`pending`/`frozen`/`archived`/nil=all) and searched over name,
  city, alias AND domain. Newest first. Returns the same shape as
  `directory_page/1`.
  """
  def admin_organizations_page(opts \\ []) do
    search = normalize_search(opts[:search])

    query =
      from(c in Organization)
      |> admin_status_filter(opts[:status])
      |> then(&if search, do: admin_search(&1, search), else: &1)

    total = Repo.aggregate(query, :count, :id)
    total_pages = max(1, ceil(total / @admin_per_page))
    page = (opts[:page] || 1) |> max(1) |> min(total_pages)

    entries =
      query
      |> order_by([c], desc: c.inserted_at)
      |> limit(^@admin_per_page)
      |> offset(^((page - 1) * @admin_per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total,
      per_page: @admin_per_page
    }
  end

  # "frozen" cuts across status (a frozen page keeps status active); the others
  # are the status itself, excluding a frozen one so the chips don't double-count.
  defp admin_status_filter(query, "frozen"), do: where(query, [c], not is_nil(c.frozen_at))

  defp admin_status_filter(query, status) when status in ~w(active pending archived),
    do: where(query, [c], c.status == ^status and is_nil(c.frozen_at))

  defp admin_status_filter(query, _all), do: query

  defp admin_search(query, term) do
    pattern = "%" <> escape_like(term) <> "%"

    from(c in query,
      where:
        ilike(c.name, ^pattern) or ilike(c.city, ^pattern) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_names cn WHERE cn.organization_id = ? AND cn.name ILIKE ?)",
            c.id,
            ^pattern
          ) or
          fragment(
            "EXISTS (SELECT 1 FROM organization_domains cd WHERE cd.organization_id = ? AND cd.domain ILIKE ?)",
            c.id,
            ^pattern
          )
    )
  end

  @doc "Everything the admin detail drawer shows for one organization, or nil."
  def admin_organization_detail(id) do
    case get_organization(id) do
      nil ->
        nil

      organization ->
        %{
          organization: organization,
          domains: list_domains(organization),
          roles: list_roles(organization),
          aliases: list_aliases(organization),
          claimed_by:
            organization.created_by_user_id &&
              Vutuv.Accounts.get_user(organization.created_by_user_id)
        }
    end
  end

  @doc "Admin freeze/unfreeze: sets/clears `frozen_at` (same effect as the report freeze)."
  def admin_set_frozen(%Organization{} = organization, frozen?) do
    frozen_at = if frozen?, do: now()
    organization |> Ecto.Changeset.change(frozen_at: frozen_at) |> Repo.update()
  end

  @doc "Archives an organization page (hides it, keeps the record and its URL reserved)."
  def archive_organization(%Organization{} = organization) do
    organization |> Organization.status_changeset("archived") |> Repo.update()
  end

  @doc """
  Whether an organization page may be hard-deleted by its owner: a page with
  job postings (issue #932) must be archived instead, so the postings and
  their history survive. Admin oversight keeps its own unconditional delete.
  """
  def deletable?(%Organization{id: id}), do: not Vutuv.Jobs.any_for_organization?(id)

  # --- images -----------------------------------------------------------------

  def get_image_by_token(token) when is_binary(token),
    do: Repo.get_by(OrganizationImage, token: token)

  def get_image_by_token(_), do: nil

  @doc """
  Stores a new logo for `organization` (replacing any previous one): writes the
  derived versions, records a `OrganizationImage` row and points `organizations.logo` at
  its token. Returns `{:ok, organization}` or `{:error, :invalid_file}`.
  """
  def store_logo(%Organization{} = organization, %User{} = user, path, filename) do
    token = OrganizationImage.gen_token()

    case Vutuv.OrganizationImageStore.store(path, filename, token) do
      {:ok, meta} ->
        # A fresh logo starts in AI-moderation limbo. Unlike avatars, the
        # `organizations.logo` pointer only ever names a *released* image: it
        # flips to the new token when the scan approves (`release_logo/1`),
        # so the current logo keeps showing meanwhile and no template ever
        # renders an unreleased byte or a broken image.
        moderation = ImageScans.initial_state()

        {:ok, image} =
          Repo.insert(%OrganizationImage{
            organization_id: organization.id,
            user_id: user.id,
            token: token,
            width: meta.width,
            height: meta.height,
            content_type: meta.content_type,
            size_bytes: meta.size_bytes,
            moderation: moderation
          })

        if moderation == "approved" do
          release_logo(image)
        else
          ImageScans.enqueue("organization_image", image.id, user.id)
          {:ok, organization}
        end

      {:error, _reason} ->
        {:error, :invalid_file}
    end
  end

  @doc """
  Points `organizations.logo` at a (released) image and purges the logo it
  displaces. Called on store when moderation is off, and by the scan verdict
  (`Vutuv.Moderation.ImageSubjects`) when it is on. Assumes organization
  images are logos (true today — revisit when the #932-style description
  gallery lands on organization pages).
  """
  def release_logo(%OrganizationImage{} = image) do
    organization = Repo.get!(Organization, image.organization_id)
    old_token = organization.logo

    {:ok, organization} =
      organization |> Ecto.Changeset.change(logo: image.token) |> Repo.update()

    if old_token && old_token != image.token, do: purge_image(old_token, organization.id)
    {:ok, organization}
  end

  @doc "Removes an organization's logo (files + row + column)."
  def remove_logo(%Organization{logo: nil} = organization), do: {:ok, organization}

  def remove_logo(%Organization{logo: token} = organization) do
    {:ok, organization} = organization |> Ecto.Changeset.change(logo: nil) |> Repo.update()
    purge_image(token, organization.id)
    {:ok, organization}
  end

  defp purge_image(token, organization_id) do
    Repo.delete_all(
      from(i in OrganizationImage,
        where: i.token == ^token and i.organization_id == ^organization_id
      )
    )

    Vutuv.OrganizationImageStore.delete(token)
  end

  @doc "Whether an organization image may be served to `viewer` (public page or owner/admin)."
  def image_visible_to?(%OrganizationImage{organization_id: nil, user_id: user_id}, %User{
        id: user_id
      }),
      do: true

  def image_visible_to?(%OrganizationImage{organization_id: nil}, _viewer), do: false

  def image_visible_to?(%OrganizationImage{organization_id: organization_id} = image, viewer) do
    case get_organization(organization_id) do
      nil ->
        false

      organization ->
        # AI-moderation limbo: until released, the bytes are uploader/admin-only.
        organization_visible_to?(organization, viewer) and
          (ImageScans.released?(image.moderation) or privileged_image_viewer?(image, viewer))
    end
  end

  defp privileged_image_viewer?(%OrganizationImage{user_id: uploader_id}, %User{
         id: uploader_id
       }),
       do: true

  defp privileged_image_viewer?(_image, %User{admin?: true}), do: true
  defp privileged_image_viewer?(_image, _viewer), do: false

  # --- deletion ---------------------------------------------------------------

  @doc """
  Deletes an organization and purges its on-disk image files. The DB cascade removes
  the domain/role/like/bookmark/image rows; only the files need explicit
  cleanup. Used by moderation/admin (organizations are never member-deleted here).
  """
  def delete_organization(%Organization{} = organization) do
    tokens = image_tokens(organization.id)
    logo_cover = Enum.reject([organization.logo, organization.cover], &is_nil/1)

    with {:ok, organization} <- Repo.delete(organization) do
      # Settle any open moderation case, then purge the on-disk image files (the
      # DB cascade already dropped the rows).
      Vutuv.Moderation.content_deleted(organization)
      for token <- Enum.uniq(tokens ++ logo_cover), do: Vutuv.OrganizationImageStore.delete(token)
      {:ok, organization}
    end
  end

  @doc "Every image token a member owns across organizations (for `Accounts.delete_user/1`)."
  def image_tokens_for_user(user_id) do
    Repo.all(from(i in OrganizationImage, where: i.user_id == ^user_id, select: i.token))
  end

  defp image_tokens(organization_id) do
    Repo.all(
      from(i in OrganizationImage, where: i.organization_id == ^organization_id, select: i.token)
    )
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
end
