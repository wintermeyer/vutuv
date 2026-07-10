defmodule Vutuv.Companies do
  @moduledoc """
  Verified company pages (issue #929). A company page can only exist once a
  member proved control of its web domain, so this context is organised around
  that trust model: a claim creates a `pending` company plus an unverified
  primary `CompanyDomain`; a successful proof (`Vutuv.Companies.Verification`)
  flips it to `active` and stamps `verified_at`. DNS / well-known domains are
  re-checked periodically with a grace window before losing verified status.

  Engagement (like + bookmark) reuses `Vutuv.Engagement`; visibility, roles and
  the public directory live here too. Moderation freeze is applied by
  `Vutuv.Moderation` (which sets `companies.frozen_at`); this context reads it
  in `company_visible_to?/2`.
  """

  import Ecto.Query, warn: false
  import Vutuv.SearchText, only: [escape_like: 1, normalize_search: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Companies.Company
  alias Vutuv.Companies.CompanyBookmark
  alias Vutuv.Companies.CompanyDomain
  alias Vutuv.Companies.CompanyImage
  alias Vutuv.Companies.CompanyLike
  alias Vutuv.Companies.CompanyRole
  alias Vutuv.Companies.Verification
  alias Vutuv.Engagement
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Repo
  alias Vutuv.SlugHelpers

  # Slugs that would shadow a /companies/<word> route.
  @reserved_slugs ~w(new)
  @directory_per_page 24
  @recheck_interval_hours 24
  @grace_days 7

  # --- fetch ------------------------------------------------------------------

  def get_company(id), do: Repo.get(Company, id)
  def get_company!(id), do: Repo.get!(Company, id)
  def get_company_by_slug(slug) when is_binary(slug), do: Repo.get_by(Company, slug: slug)
  def get_company_by_slug(_), do: nil

  @doc """
  Fetches an active, non-frozen company by slug for a public viewer, or the
  page for an owner/admin who may see it while `pending`/`frozen`. Returns
  `{:error, :not_found}` otherwise.
  """
  def fetch_visible_company(slug, viewer) do
    case get_company_by_slug(slug) do
      nil ->
        {:error, :not_found}

      company ->
        if company_visible_to?(company, viewer), do: {:ok, company}, else: {:error, :not_found}
    end
  end

  @doc "Whether `viewer` may see `company` at all (public active page, or owner/admin)."
  def company_visible_to?(%Company{} = company, viewer) do
    public_visible?(company) or can_manage?(company, viewer) or admin?(viewer)
  end

  @doc "Whether `company` is on the public site (active and not frozen)."
  def public_visible?(%Company{status: "active", frozen_at: nil}), do: true
  def public_visible?(_), do: false

  @doc "Whether the page appears in machine channels (sitemap, JSON-LD): active + seo?."
  def indexable?(%Company{seo?: true} = company), do: public_visible?(company)
  def indexable?(_), do: false

  @doc "Whether the agent-format siblings (.md/.txt/.json/.xml) are served: active + geo?."
  def agent_visible?(%Company{geo?: true} = company), do: public_visible?(company)
  def agent_visible?(_), do: false

  # --- roles ------------------------------------------------------------------

  @doc "Whether `user` may manage `company` (creator or a role holder)."
  def can_manage?(%Company{} = company, %User{} = user) do
    company.created_by_user_id == user.id or role_holder?(company.id, user.id)
  end

  def can_manage?(_, _), do: false

  defp role_holder?(company_id, user_id) do
    Repo.exists?(
      from(r in CompanyRole, where: r.company_id == ^company_id and r.user_id == ^user_id)
    )
  end

  defp admin?(%User{admin?: true}), do: true
  defp admin?(_), do: false

  # --- claim + create ---------------------------------------------------------

  @doc "A blank create changeset for the claim wizard form."
  def change_new_company(attrs \\ %{}), do: Company.create_changeset(%Company{}, attrs)

  @doc "An edit changeset for the owner form."
  def change_company(%Company{} = company, attrs \\ %{}),
    do: Company.edit_changeset(company, attrs)

  @doc """
  Creates a `pending` company from the claim wizard: the company + an owner
  role + an unverified primary domain (derived from the website URL, using the
  chosen `method`). Returns `{:ok, %{company: c, domain: d}}`,
  `{:error, :domain_taken}` when the domain already belongs to another company,
  or `{:error, changeset}`.
  """
  def create_pending_company(%User{} = user, attrs, method) when method in ~w(dns well_known) do
    changeset =
      %Company{created_by_user_id: user.id, status: "pending"}
      |> Company.create_changeset(attrs)
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
      SlugHelpers.gen_slug_unique(String.slice(name, 0, 120), Company, :slug, @reserved_slugs)

    host = CompanyDomain.normalize(Ecto.Changeset.get_field(changeset, :website_url))
    token = Verification.gen_token()

    company_changeset =
      changeset
      |> Ecto.Changeset.put_change(:slug, slug)
      |> Ecto.Changeset.validate_length(:slug, max: 255)
      |> Ecto.Changeset.unique_constraint(:slug)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:company, company_changeset)
    |> Ecto.Multi.insert(:role, fn %{company: company} ->
      CompanyRole.changeset(%CompanyRole{}, %{
        company_id: company.id,
        user_id: user.id,
        role: "owner",
        granted_by_user_id: user.id
      })
    end)
    |> Ecto.Multi.insert(:domain, fn %{company: company} ->
      CompanyDomain.changeset(%CompanyDomain{}, %{
        company_id: company.id,
        domain: host,
        primary?: true,
        method: method,
        verification_token: token
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{company: _, domain: _} = result} -> {:ok, result}
      {:error, :domain, _changeset, _} -> {:error, :domain_taken}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # --- owner edit -------------------------------------------------------------

  @doc "Applies the owner edit form; keeps the slug stable (renames keep the URL)."
  def update_company(%Company{} = company, attrs) do
    company
    |> Company.edit_changeset(attrs)
    |> Repo.update()
  end

  # --- verification -----------------------------------------------------------

  @doc "All of a company's domains, primary first. A company has very few."
  def list_domains(%Company{id: id}) do
    Repo.all(
      from(d in CompanyDomain,
        where: d.company_id == ^id,
        order_by: [desc: d.primary?, asc: d.inserted_at]
      )
    )
  end

  @doc "The primary (claim) domain of a company."
  def primary_domain(%Company{} = company), do: Enum.find(list_domains(company), & &1.primary?)

  @doc "A company's currently verified domains, primary first."
  def verified_domains(%Company{} = company),
    do: Enum.filter(list_domains(company), & &1.verified_at)

  defp verified_domain_count(company_id) do
    Repo.aggregate(
      from(d in CompanyDomain, where: d.company_id == ^company_id and not is_nil(d.verified_at)),
      :count,
      :id
    )
  end

  @doc "The TXT value a member must publish for DNS verification."
  def dns_txt_value(%CompanyDomain{verification_token: token}),
    do: Verification.dns_txt_value(token)

  @doc "The well-known file URL and content for the `well_known` method."
  def well_known_url(%CompanyDomain{domain: host}), do: Verification.well_known_url(host)
  def well_known_content(%CompanyDomain{verification_token: token}), do: token

  @doc "Whether domain verification (DNS TXT + well-known) is enabled for this install."
  def verification_enabled?, do: Verification.enabled?()

  @doc "Runs the domain's current verification method; on success activates the company."
  def verify_domain(%Company{} = company, %CompanyDomain{method: "dns"} = domain),
    do: verify_dns(company, domain)

  def verify_domain(%Company{} = company, %CompanyDomain{method: "well_known"} = domain),
    do: verify_well_known(company, domain)

  @doc "Switches a pending domain between the DNS and well-known methods (same token)."
  def set_domain_method(%CompanyDomain{} = domain, method) when method in ~w(dns well_known) do
    domain |> Ecto.Changeset.change(method: method) |> Repo.update()
  end

  @doc "Verifies a DNS domain; on success activates the company."
  def verify_dns(%Company{} = company, %CompanyDomain{method: "dns"} = domain) do
    if verification_enabled?() and
         Verification.dns_verified?(domain.domain, domain.verification_token) do
      activate(company, domain)
    else
      {:error, :not_found}
    end
  end

  @doc "Verifies a well-known-file domain; on success activates the company."
  def verify_well_known(%Company{} = company, %CompanyDomain{method: "well_known"} = domain) do
    if verification_enabled?() and
         Verification.well_known_verified?(domain.domain, domain.verification_token) do
      activate(company, domain)
    else
      {:error, :not_found}
    end
  end

  # Flips a pending company to active off a freshly verified domain, stamps
  # verified_at once, and alerts the operator on first verification.
  defp activate(%Company{} = company, %CompanyDomain{} = domain) do
    now = now()
    first? = is_nil(company.verified_at)

    company_changeset =
      company
      |> Company.status_changeset("active")
      |> then(fn cs ->
        if first?, do: Ecto.Changeset.put_change(cs, :verified_at, now), else: cs
      end)

    {:ok, %{company: company, domain: domain}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(
        :domain,
        CompanyDomain.check_changeset(domain, %{
          verified_at: now,
          last_checked_at: now,
          grace_deadline_at: nil
        })
      )
      |> Ecto.Multi.update(:company, company_changeset)
      |> Repo.transaction()

    if first? do
      company
      |> Emailer.company_verified_notice(domain)
      |> Emailer.deliver()
    end

    {:ok, company}
  end

  # --- periodic re-check ------------------------------------------------------

  @doc "DNS / well-known domains whose last check is older than the interval."
  def domains_due_for_recheck(now \\ NaiveDateTime.utc_now()) do
    cutoff = NaiveDateTime.add(now, -@recheck_interval_hours * 3600)

    Repo.all(
      from(d in CompanyDomain,
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
      |> Enum.count(fn {:ok, outcome} -> outcome in [:demoted_domain, :demoted_company] end)
    else
      0
    end
  end

  @doc """
  Re-checks one domain. On success refreshes `last_checked_at` and clears any
  grace window. On failure starts a grace window, waits it out, then demotes the
  domain (and the company, if it was its last verified domain, alerting the
  operator). Returns an outcome atom.
  """
  def recheck_domain(%CompanyDomain{} = domain) do
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
      |> CompanyDomain.check_changeset(%{last_checked_at: now, grace_deadline_at: nil})
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
        |> CompanyDomain.check_changeset(%{last_checked_at: now, grace_deadline_at: deadline})
        |> Repo.update()

        :grace_started

      NaiveDateTime.compare(now, domain.grace_deadline_at) == :lt ->
        domain
        |> CompanyDomain.check_changeset(%{last_checked_at: now})
        |> Repo.update()

        :in_grace

      true ->
        demote_domain(domain, now)
    end
  end

  defp demote_domain(domain, now) do
    {:ok, domain} =
      domain
      |> CompanyDomain.check_changeset(%{
        verified_at: nil,
        last_checked_at: now,
        grace_deadline_at: nil
      })
      |> Repo.update()

    company = get_company!(domain.company_id)

    if verified_domain_count(company.id) == 0 do
      {:ok, company} = company |> Company.status_changeset("pending") |> Repo.update()

      company
      |> Emailer.company_unverified_notice(domain)
      |> Emailer.deliver()

      :demoted_company
    else
      :demoted_domain
    end
  end

  # --- engagement (like + bookmark) ------------------------------------------

  def like_company(%User{} = user, %Company{} = company),
    do: engage(CompanyLike, :like, user, company)

  def unlike_company(%User{} = user, %Company{} = company),
    do: disengage(CompanyLike, :like, user, company)

  def bookmark_company(%User{} = user, %Company{} = company),
    do: engage(CompanyBookmark, :bookmark, user, company)

  def unbookmark_company(%User{} = user, %Company{} = company),
    do: disengage(CompanyBookmark, :bookmark, user, company)

  defp engage(schema, kind, %User{} = user, %Company{} = company) do
    case Engagement.insert_if_new(schema, %{user_id: user.id, company_id: company.id}, [
           :company_id,
           :user_id
         ]) do
      :exists ->
        {:ok, :noop}

      {:inserted, row} ->
        broadcast_engagement(kind, user.id, company.id, true)
        {:ok, row}
    end
  end

  defp disengage(schema, kind, %User{} = user, %Company{} = company) do
    {count, _} =
      Repo.delete_all(
        from(e in schema, where: e.company_id == ^company.id and e.user_id == ^user.id)
      )

    if count > 0, do: broadcast_engagement(kind, user.id, company.id, false)
    :ok
  end

  @doc """
  Public like count plus the viewer's own `liked?`/`bookmarked?` flags for the
  action bar. An anonymous viewer gets `false` flags.
  """
  def company_engagement(%Company{id: company_id}, viewer) do
    viewer_id = viewer && viewer.id

    %{
      likes: like_count(company_id),
      liked?: viewer_id != nil and engaged?(CompanyLike, company_id, viewer_id),
      bookmarked?: viewer_id != nil and engaged?(CompanyBookmark, company_id, viewer_id)
    }
  end

  defp like_count(company_id) do
    Repo.aggregate(from(l in CompanyLike, where: l.company_id == ^company_id), :count, :id)
  end

  defp engaged?(schema, company_id, user_id) do
    Repo.exists?(from(e in schema, where: e.company_id == ^company_id and e.user_id == ^user_id))
  end

  @doc "Subscribes to a company's live counter topic."
  def subscribe(company_id), do: Phoenix.PubSub.subscribe(Vutuv.PubSub, topic(company_id))

  defp topic(company_id), do: "company:#{company_id}"

  defp broadcast_engagement(kind, user_id, company_id, active?) do
    # The per-company topic carries the absolute like count to every open page;
    # the actor's activity topic tells the /bookmarks hub to add or drop a card.
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      topic(company_id),
      {:company_counters, %{company_id: company_id, likes: like_count(company_id)}}
    )

    Vutuv.Activity.broadcast(
      user_id,
      {:company_engagement_changed, %{kind: kind, company_id: company_id, active?: active?}}
    )
  end

  @doc "A member's bookmarked companies (private saved-items hub), newest first."
  def bookmarked_companies(%User{id: user_id}) do
    Repo.all(
      from(c in Company,
        join: e in CompanyBookmark,
        on: e.company_id == c.id,
        where: e.user_id == ^user_id and c.status == "active" and is_nil(c.frozen_at),
        order_by: [desc: e.inserted_at],
        select: c
      )
    )
  end

  @doc """
  One page of the member's liked / bookmarked companies for the `/bookmarks`
  saved-items hub, honoring its search (`name`/`city`) and sort. Returns
  `%{entries:, more?:, next_offset:}` (offset pagination), like the posts pages.
  """
  def saved_companies_page(%User{id: user_id}, kind, opts) when kind in [:like, :bookmark] do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    search = normalize_search(opts[:search])
    schema = if kind == :like, do: CompanyLike, else: CompanyBookmark

    query =
      from(c in Company,
        join: e in ^schema,
        as: :engagement,
        on: e.company_id == c.id,
        where: e.user_id == ^user_id and c.status == "active" and is_nil(c.frozen_at)
      )

    query = if search, do: name_or_city_ilike(query, search), else: query

    entries =
      query
      |> saved_order(opts[:sort])
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> select([c], c)
      |> Repo.all()

    {shown, more?} =
      if length(entries) > limit, do: {Enum.take(entries, limit), true}, else: {entries, false}

    %{entries: shown, more?: more?, next_offset: offset + length(shown)}
  end

  defp saved_order(query, :oldest), do: order_by(query, [engagement: e], asc: e.inserted_at)
  defp saved_order(query, :name), do: order_by(query, [c], asc: fragment("lower(?)", c.name))
  defp saved_order(query, _recent), do: order_by(query, [engagement: e], desc: e.inserted_at)

  # --- directory --------------------------------------------------------------

  @doc """
  A page of the public directory: active, non-frozen companies, ordered by name,
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
    do: from(c in Company, where: c.status == "active" and is_nil(c.frozen_at))

  defp directory_query(term), do: name_or_city_ilike(directory_query(nil), term)

  # Case-insensitive match on name OR city, with the LIKE wildcards escaped.
  defp name_or_city_ilike(query, term) do
    pattern = "%" <> escape_like(term) <> "%"
    from(c in query, where: ilike(c.name, ^pattern) or ilike(c.city, ^pattern))
  end

  @doc """
  The active + non-frozen + seo? company set: the one definition of "indexable"
  shared by the sitemap (mirrors how `Sitemap` delegates the member set to
  `Vutuv.Directory`, so the two can never drift).
  """
  def indexable_query do
    from(c in Company, where: c.status == "active" and is_nil(c.frozen_at) and c.seo?)
  end

  # --- images -----------------------------------------------------------------

  def get_image_by_token(token) when is_binary(token), do: Repo.get_by(CompanyImage, token: token)
  def get_image_by_token(_), do: nil

  @doc """
  Stores a new logo for `company` (replacing any previous one): writes the
  derived versions, records a `CompanyImage` row and points `companies.logo` at
  its token. Returns `{:ok, company}` or `{:error, :invalid_file}`.
  """
  def store_logo(%Company{} = company, %User{} = user, path, filename) do
    token = CompanyImage.gen_token()

    case Vutuv.CompanyImageStore.store(path, filename, token) do
      {:ok, meta} ->
        old_token = company.logo

        {:ok, _image} =
          Repo.insert(%CompanyImage{
            company_id: company.id,
            user_id: user.id,
            token: token,
            width: meta.width,
            height: meta.height,
            content_type: meta.content_type,
            size_bytes: meta.size_bytes
          })

        {:ok, company} = company |> Ecto.Changeset.change(logo: token) |> Repo.update()
        if old_token, do: purge_image(old_token, company.id)
        {:ok, company}

      {:error, _reason} ->
        {:error, :invalid_file}
    end
  end

  @doc "Removes a company's logo (files + row + column)."
  def remove_logo(%Company{logo: nil} = company), do: {:ok, company}

  def remove_logo(%Company{logo: token} = company) do
    {:ok, company} = company |> Ecto.Changeset.change(logo: nil) |> Repo.update()
    purge_image(token, company.id)
    {:ok, company}
  end

  defp purge_image(token, company_id) do
    Repo.delete_all(
      from(i in CompanyImage, where: i.token == ^token and i.company_id == ^company_id)
    )

    Vutuv.CompanyImageStore.delete(token)
  end

  @doc "Whether a company image may be served to `viewer` (public page or owner/admin)."
  def image_visible_to?(%CompanyImage{company_id: nil, user_id: user_id}, %User{id: user_id}),
    do: true

  def image_visible_to?(%CompanyImage{company_id: nil}, _viewer), do: false

  def image_visible_to?(%CompanyImage{company_id: company_id}, viewer) do
    case get_company(company_id) do
      nil -> false
      company -> company_visible_to?(company, viewer)
    end
  end

  # --- deletion ---------------------------------------------------------------

  @doc """
  Deletes a company and purges its on-disk image files. The DB cascade removes
  the domain/role/like/bookmark/image rows; only the files need explicit
  cleanup. Used by moderation/admin (companies are never member-deleted here).
  """
  def delete_company(%Company{} = company) do
    tokens = image_tokens(company.id)
    logo_cover = Enum.reject([company.logo, company.cover], &is_nil/1)

    with {:ok, company} <- Repo.delete(company) do
      # Settle any open moderation case, then purge the on-disk image files (the
      # DB cascade already dropped the rows).
      Vutuv.Moderation.content_deleted(company)
      for token <- Enum.uniq(tokens ++ logo_cover), do: Vutuv.CompanyImageStore.delete(token)
      {:ok, company}
    end
  end

  @doc "Every image token a member owns across companies (for `Accounts.delete_user/1`)."
  def image_tokens_for_user(user_id) do
    Repo.all(from(i in CompanyImage, where: i.user_id == ^user_id, select: i.token))
  end

  defp image_tokens(company_id) do
    Repo.all(from(i in CompanyImage, where: i.company_id == ^company_id, select: i.token))
  end

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
end
