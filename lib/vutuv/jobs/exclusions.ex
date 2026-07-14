defmodule Vutuv.Jobs.Exclusions do
  @moduledoc """
  The job-posting exclusion seam (issue #939): who a posting is subtracted from
  as the LAST step of its visibility gate (subtracting never adds), the
  poster-side twin of the member exclusion list (`Vutuv.Accounts.ViewerExclusion`,
  issue #938).

  A viewer is excluded from a posting when they match any row on the posting's
  **effective** exclusion set — the posting's own rows **∪** the standing default
  rows of the organization it is attributed to — on any of three dimensions:

    * **member** — the viewer's own account, or
    * **organization** — an organization the viewer belongs to (role holder, or
      **current** work experience linked to it, or a confirmed email at one of
      its verified domains), or
    * **domain** — a confirmed email at that domain or any subdomain of it.

  A full **block** (`Vutuv.Social.block_user`, either direction) implies the same
  exclusion, and the poster and the owning organization's staff are never excluded
  from their own posting. An **anonymous** viewer (no account) is never excluded —
  exclusion can only narrow the signed-in on-platform audience; the base
  `everyone`/`members` visibility governs the crawlable formats.

  The one predicate `excluded?/2` (single posting) and `exclude_for_viewer/2`
  (a board/list query subtraction) resolve the viewer's scope once and share the
  same matching, so no surface can disagree on who sees a posting.
  """

  import Ecto.Query

  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.EmailDomain
  alias Vutuv.Handles
  alias Vutuv.Jobs.{JobExclusion, JobPosting}
  alias Vutuv.Organizations
  alias Vutuv.Organizations.{Organization, OrganizationDomain, OrganizationRole}
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social

  # A generous cap on a single subject's list (per-posting and per-organization
  # alike), so a pathological list can't unbound the matching query.
  @cap 200

  @doc "The maximum number of entries on one subject's exclusion list."
  def cap, do: @cap

  # The subdomain-aware host match shared by the org-domain lookup and the
  # viewer-scope match: a confirmed host equals the domain or is a subdomain of
  # it. Kept as one literal so the two fragment call sites can't drift apart.
  @host_match_sql "EXISTS (SELECT 1 FROM unnest(?::text[]) AS eh(host) WHERE eh.host = ? OR eh.host LIKE '%.' || ?)"

  # --- reads ----------------------------------------------------------------

  @doc "A posting's own exclusion rows, newest first, targets preloaded."
  def list_for_posting(%JobPosting{id: id}),
    do: list_subject(from(x in JobExclusion, where: x.job_posting_id == ^id))

  @doc "An organization's standing-default exclusion rows, newest first, targets preloaded."
  def list_for_organization(%Organization{id: id}),
    do: list_subject(from(x in JobExclusion, where: x.organization_id == ^id))

  defp list_subject(query) do
    query
    |> order_by([x], desc: x.inserted_at, desc: x.id)
    |> preload([:excluded_user, :excluded_organization])
    |> Repo.all()
  end

  @doc "An empty domain changeset for a posting's list (drives the editor form)."
  def change_posting_domain(%JobPosting{} = posting),
    do: JobExclusion.domain_changeset(posting_subject(posting), %{})

  @doc "An empty domain changeset for an organization's default list."
  def change_organization_domain(%Organization{} = organization),
    do: JobExclusion.domain_changeset(organization_subject(organization), %{})

  # --- writes: per-posting subject ------------------------------------------

  @doc "Excludes a member (by @handle) from `posting`. Never the poster."
  def add_posting_member(%JobPosting{} = posting, handle) do
    with :ok <- ensure_room(posting_subject(posting)),
         {:ok, user} <- lookup_member(handle),
         :ok <- refuse_poster(posting, user) do
      insert_member(posting_subject(posting), user)
    end
  end

  @doc "Excludes an organization (by @handle/slug) from `posting`. Never the owning organization."
  def add_posting_organization(%JobPosting{} = posting, identifier) do
    with :ok <- ensure_room(posting_subject(posting)),
         {:ok, org} <- lookup_organization(identifier),
         :ok <- refuse_owning_organization(posting, org) do
      insert_organization(posting_subject(posting), org)
    end
  end

  @doc "Excludes an email domain from `posting`."
  def add_posting_domain(%JobPosting{} = posting, params),
    do: insert_domain(posting_subject(posting), params)

  @doc "Removes one of `posting`'s own rows (scoped to the posting)."
  def remove_from_posting(%JobPosting{id: pid}, id),
    do: delete_scoped(from(x in JobExclusion, where: x.id == ^id and x.job_posting_id == ^pid))

  # --- writes: organization standing-default subject ------------------------

  @doc "Excludes a member (by @handle) from all of `organization`'s postings."
  def add_organization_member(%Organization{} = organization, handle) do
    with :ok <- ensure_room(organization_subject(organization)),
         {:ok, user} <- lookup_member(handle) do
      insert_member(organization_subject(organization), user)
    end
  end

  @doc "Excludes another organization from all of `organization`'s postings. Never itself."
  def add_organization_organization(%Organization{} = organization, identifier) do
    with :ok <- ensure_room(organization_subject(organization)),
         {:ok, org} <- lookup_organization(identifier),
         :ok <- refuse_self_organization(organization, org) do
      insert_organization(organization_subject(organization), org)
    end
  end

  @doc "Excludes an email domain from all of `organization`'s postings."
  def add_organization_domain(%Organization{} = organization, params),
    do: insert_domain(organization_subject(organization), params)

  @doc "Removes one of `organization`'s standing-default rows (scoped to the organization)."
  def remove_from_organization(%Organization{id: oid}, id),
    do: delete_scoped(from(x in JobExclusion, where: x.id == ^id and x.organization_id == ^oid))

  # --- the predicate --------------------------------------------------------

  @doc """
  Whether `viewer` is excluded from `posting`. The poster, the owning
  organization's staff and an anonymous viewer are never excluded; a block (either
  direction) always excludes; otherwise the effective exclusion set decides.
  """
  def excluded?(_posting, nil), do: false

  def excluded?(%JobPosting{} = posting, %User{} = viewer) do
    cond do
      posting.user_id == viewer.id -> false
      Social.blocked_between?(posting.user_id, viewer.id) -> true
      owning_org_staff?(posting, viewer) -> false
      true -> on_effective_list?(posting, viewer)
    end
  end

  @doc """
  Subtracts every posting `viewer` is excluded from (their effective list only —
  the shared board query already subtracts blocks) from `query`. A no-op for an
  anonymous viewer. `query`'s first binding must be the `JobPosting`.
  """
  def exclude_for_viewer(query, nil), do: query

  def exclude_for_viewer(query, %User{} = viewer) do
    excluded = viewer |> resolve_scope() |> matching_posting_ids()
    where(query, [p], p.id not in subquery(excluded))
  end

  # --- viewer scope ---------------------------------------------------------

  @doc """
  Resolves the viewer's exclusion-matching scope once: their account id, the
  hosts of their confirmed emails, and the ids of every organization they belong
  to (role holder ∪ current work experience ∪ confirmed email at a verified
  domain). Shared by `excluded?/2` and `exclude_for_viewer/2`.
  """
  def resolve_scope(%User{id: viewer_id}) do
    hosts = viewer_email_hosts(viewer_id)
    %{viewer_id: viewer_id, email_hosts: hosts, org_ids: viewer_org_ids(viewer_id, hosts)}
  end

  defp viewer_email_hosts(viewer_id) do
    from(e in Email, where: e.user_id == ^viewer_id, select: e.value)
    |> Repo.all()
    |> Enum.map(&EmailDomain.host_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp viewer_org_ids(viewer_id, hosts) do
    role_ids =
      Repo.all(
        from(r in OrganizationRole, where: r.user_id == ^viewer_id, select: r.organization_id)
      )

    # "Current" = an ongoing role (no end date), linked to a verified organization.
    workexp_ids =
      Repo.all(
        from(w in WorkExperience,
          where: w.user_id == ^viewer_id and not is_nil(w.organization_id) and is_nil(w.end_year),
          select: w.organization_id
        )
      )

    Enum.uniq(role_ids ++ workexp_ids ++ orgs_with_matching_domain(hosts))
  end

  defp orgs_with_matching_domain([]), do: []

  defp orgs_with_matching_domain(hosts) do
    Repo.all(
      from(d in OrganizationDomain,
        where: not is_nil(d.verified_at),
        where: fragment(@host_match_sql, ^hosts, d.domain, d.domain),
        select: d.organization_id,
        distinct: true
      )
    )
  end

  # The posting ids whose effective exclusion set (own rows ∪ owning-org default
  # rows) matches this viewer scope. `p.organization_id IS NULL` never equals a
  # default row's non-null organization_id, so personal postings match only their
  # own rows.
  defp matching_posting_ids(scope) do
    from(p in JobPosting,
      join: x in JobExclusion,
      as: :x,
      on: x.job_posting_id == p.id or x.organization_id == p.organization_id,
      where: ^scope_match(scope),
      select: p.id
    )
  end

  defp on_effective_list?(%JobPosting{} = posting, %User{} = viewer) do
    scope = resolve_scope(viewer)

    subject =
      case posting.organization_id do
        nil -> dynamic([x: x], x.job_posting_id == ^posting.id)
        org_id -> dynamic([x: x], x.job_posting_id == ^posting.id or x.organization_id == ^org_id)
      end

    from(x in JobExclusion, as: :x)
    |> where(^subject)
    |> where(^scope_match(scope))
    |> Repo.exists?()
  end

  # The dimension match against a resolved viewer scope, as a dynamic over the
  # named `JobExclusion` binding `:x` (so it composes into either the board
  # subquery or the single-posting exists, whichever binding position `:x` sits
  # at). Empty org list → `in ^[]` renders false; empty host list → the EXISTS
  # over an empty array is false. So an all-empty scope matches nothing.
  defp scope_match(%{viewer_id: viewer_id, email_hosts: hosts, org_ids: org_ids}) do
    dynamic(
      [x: x],
      x.excluded_user_id == ^viewer_id or
        x.excluded_organization_id in ^org_ids or
        fragment(@host_match_sql, ^hosts, x.domain, x.domain)
    )
  end

  defp owning_org_staff?(%JobPosting{organization_id: nil}, _viewer), do: false

  defp owning_org_staff?(%JobPosting{organization_id: org_id}, %User{id: viewer_id}) do
    Repo.exists?(
      from(r in OrganizationRole,
        where: r.organization_id == ^org_id and r.user_id == ^viewer_id
      )
    )
  end

  # --- shared write helpers -------------------------------------------------

  defp posting_subject(%JobPosting{id: id}), do: %{job_posting_id: id}
  defp organization_subject(%Organization{id: id}), do: %{organization_id: id}

  defp insert_member(subject, user) do
    subject
    |> JobExclusion.member_changeset(user)
    |> Repo.insert()
    |> constraint_to_duplicate()
  end

  defp insert_organization(subject, org) do
    subject
    |> JobExclusion.organization_changeset(org)
    |> Repo.insert()
    |> constraint_to_duplicate()
  end

  defp insert_domain(subject, params) do
    subject
    |> JobExclusion.domain_changeset(params)
    |> then(fn changeset ->
      if room?(subject),
        do: Repo.insert(changeset),
        else: {:error, full_changeset(changeset)}
    end)
  end

  # Usernames are stored lowercase, so normalize the typed @handle the same way
  # the rest of the app does, otherwise "@JohnDoe" would fail to resolve here.
  defp lookup_member(handle) when is_binary(handle) do
    slug = Handles.normalize(handle)

    case slug != "" && Vutuv.Accounts.get_user_by_username(slug) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  defp lookup_member(_), do: {:error, :not_found}

  defp lookup_organization(identifier) when is_binary(identifier) do
    slug = Handles.normalize(identifier)

    org =
      slug != "" &&
        (Organizations.get_organization_by_username(slug) ||
           Organizations.get_organization_by_slug(slug))

    case org do
      %Organization{} = org -> {:ok, org}
      _ -> {:error, :not_found}
    end
  end

  defp lookup_organization(_), do: {:error, :not_found}

  defp refuse_poster(%JobPosting{user_id: user_id}, %User{id: user_id}), do: {:error, :poster}
  defp refuse_poster(_posting, _user), do: :ok

  defp refuse_owning_organization(%JobPosting{organization_id: id}, %Organization{id: id}),
    do: {:error, :owning_org}

  defp refuse_owning_organization(_posting, _org), do: :ok

  defp refuse_self_organization(%Organization{id: id}, %Organization{id: id}), do: {:error, :self}
  defp refuse_self_organization(_organization, _org), do: :ok

  defp ensure_room(subject), do: if(room?(subject), do: :ok, else: {:error, :full})

  defp room?(subject), do: subject_count(subject) < @cap

  defp subject_count(%{job_posting_id: id}),
    do: Repo.aggregate(from(x in JobExclusion, where: x.job_posting_id == ^id), :count)

  defp subject_count(%{organization_id: id}),
    do: Repo.aggregate(from(x in JobExclusion, where: x.organization_id == ^id), :count)

  # Translate the partial-unique-index violation into the friendly `:duplicate`
  # atom the member/organization forms show as a one-liner.
  defp constraint_to_duplicate({:ok, _} = ok), do: ok

  defp constraint_to_duplicate({:error, changeset}) do
    if Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
         Keyword.get(opts, :constraint) == :unique
       end),
       do: {:error, :duplicate},
       else: {:error, changeset}
  end

  defp full_changeset(changeset) do
    changeset
    |> Ecto.Changeset.add_error(:domain, "this list is full (max %{count})", count: @cap)
    |> Map.put(:action, :insert)
  end

  defp delete_scoped(query) do
    Repo.delete_all(query)
    :ok
  end
end
