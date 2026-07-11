defmodule Vutuv.Jobs do
  @moduledoc """
  The Jobs context (issue #932): job postings and their 90-day lifecycle,
  engagement (like + bookmark), tags, structured location, the salary model and
  the poster's visibility toggles.

  ## Lifecycle

      draft ──publish──▶ published ──expires_on passes──▶ expired ──30 days──▶ owner-only
                           │
                           └──close (filled | withdrawn)──▶ closed

  Publishing sets `expires_on` to today (Berlin) + `runtime_days/0` (90). There
  is **no renewal or bumping**: a still-open role gets a fresh posting via
  `repost/1`, keeping the hard guarantee that nothing on the board is older than
  90 days. The nightly `Vutuv.Jobs.Sweeper` flips overdue postings to `expired`
  and demotes those expired more than 30 days ago to owner-only.

  ## Visibility

  Three orthogonal gates, mirroring the organization pages:

    * `visibility` (everyone/members) — the human audience.
    * `seo?` — machine indexing (sitemap + JSON-LD).
    * `geo?` — the machine-readable agent formats (.md/.txt/.json/.xml).

  `visible_to?/2` is the one predicate the detail page, the board (#933) and the
  agent docs read.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Engagement
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Jobs.JobPostingBookmark
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Jobs.JobPostingLike
  alias Vutuv.Jobs.JobPostingTag
  alias Vutuv.Organizations
  alias Vutuv.Repo
  alias Vutuv.Salary
  alias Vutuv.Tags.Tag

  # A posting stays publicly reachable (with an "unavailable" banner, noindex,
  # no JSON-LD) for this many days after it expires or is closed, then drops to
  # owner-only.
  @public_grace_days 30
  # Publishing requires an account at least this old.
  @min_account_age_days 3

  # --- config ---------------------------------------------------------------

  defp config, do: Application.get_env(:vutuv, :jobs, [])

  @doc "How long a published posting stays live before auto-expiry (days)."
  def runtime_days, do: Keyword.get(config(), :default_runtime_days, 90)

  @doc "The maximum concurrently-published postings for one member."
  def max_published_per_member, do: Keyword.get(config(), :max_published_per_member, 3)

  @doc "The maximum concurrently-published postings for one organization."
  def max_published_per_organization,
    do: Keyword.get(config(), :max_published_per_organization, 10)

  defp image_config, do: Application.get_env(:vutuv, :job_posting_images, [])
  def max_images_per_posting, do: Keyword.get(image_config(), :max_per_post, 10)
  def max_image_filesize, do: Keyword.get(image_config(), :max_filesize, 6_000_000)

  # --- fetch ----------------------------------------------------------------

  def get_job_posting(id), do: Repo.get(JobPosting, id)
  def get_job_posting!(id), do: Repo.get!(JobPosting, id)

  @doc "Fetches a posting by slug with everything a page needs preloaded, or nil."
  def get_job_posting_by_slug(slug) when is_binary(slug) do
    JobPosting
    |> Repo.get_by(slug: slug)
    |> preload_for_show()
  end

  @doc """
  Fetches a posting the `viewer` may see (`{:ok, posting}`), else
  `{:error, :not_found}` — so an invisible posting is indistinguishable from a
  missing one. The row is **not** preloaded (the visibility check needs only
  scalar fields); a consumer that renders associations calls `preload_for_show/1`.
  """
  def fetch_visible_job_posting(slug, viewer) do
    case Repo.get_by(JobPosting, slug: slug) do
      %JobPosting{} = posting ->
        if visible_to?(posting, viewer), do: {:ok, posting}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Preloads the user, organization, ordered tags and images for a show/edit page."
  def preload_for_show(nil), do: nil

  def preload_for_show(%JobPosting{} = posting) do
    Repo.preload(posting, [
      :user,
      :organization,
      [job_posting_tags: :tag],
      images: from(i in JobPostingImage, order_by: [asc: i.position, asc: i.inserted_at])
    ])
  end

  @doc """
  One page of a member's own postings for the `/jobs/mine` dashboard, filtered
  by the tab's status. Returns `%{entries:, more?:, next_offset:}`.
  """
  def list_own_postings(%User{id: user_id}, status, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    entries =
      JobPosting
      |> where([p], p.user_id == ^user_id and p.status == ^status)
      |> order_by([p], desc: p.updated_at)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload(:organization)

    {shown, more?} =
      if length(entries) > limit, do: {Enum.take(entries, limit), true}, else: {entries, false}

    %{entries: shown, more?: more?, next_offset: offset + length(shown)}
  end

  @doc "Count of a member's postings in each status, for the dashboard tab badges."
  def own_status_counts(%User{id: user_id}) do
    JobPosting
    |> where([p], p.user_id == ^user_id)
    |> group_by([p], p.status)
    |> select([p], {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  def change_job_posting(%JobPosting{} = posting, attrs \\ %{}),
    do: JobPosting.changeset(posting, attrs)

  # --- visibility -----------------------------------------------------------

  @doc "Whether `user` owns `posting`."
  def owner?(%JobPosting{user_id: user_id}, %User{id: user_id}), do: true
  def owner?(_, _), do: false

  defp admin?(%User{admin?: true}), do: true
  defp admin?(_), do: false

  @doc """
  The posting's status accounting for the calendar: a `published` posting past
  its `expires_on` reads as `expired` even before the nightly sweeper flips it.
  """
  def effective_status(%JobPosting{status: :published} = posting) do
    if past_expiry?(posting), do: :expired, else: :published
  end

  def effective_status(%JobPosting{status: status}), do: status

  defp past_expiry?(%JobPosting{expires_on: nil}), do: false
  defp past_expiry?(%JobPosting{expires_on: on}), do: Date.compare(BerlinTime.today(), on) == :gt

  # Beyond the 30-day public grace window after expiry/close → owner-only.
  defp stale?(%JobPosting{} = posting) do
    reference =
      cond do
        posting.closed_at != nil -> NaiveDateTime.to_date(posting.closed_at)
        posting.expires_on != nil -> posting.expires_on
        true -> nil
      end

    effective_status(posting) in [:expired, :closed] and reference != nil and
      Date.diff(BerlinTime.today(), reference) > @public_grace_days
  end

  @doc "Whether `viewer` may see `posting`. Owner/admin see any state."
  def visible_to?(%JobPosting{} = posting, viewer) do
    cond do
      owner?(posting, viewer) or admin?(viewer) -> true
      posting.frozen_at != nil -> false
      stale?(posting) -> false
      posting.visibility == :members -> viewer != nil
      posting.visibility == :everyone -> effective_status(posting) != :draft
      true -> false
    end
  end

  @doc "Whether the posting is currently a live, public listing (board, JSON-LD base)."
  def live?(%JobPosting{} = posting) do
    posting.status == :published and posting.frozen_at == nil and
      posting.visibility == :everyone and not past_expiry?(posting)
  end

  @doc "Whether the posting appears in machine indexing channels (sitemap + JSON-LD): live + seo?."
  def indexable?(%JobPosting{seo?: true} = posting), do: live?(posting)
  def indexable?(_), do: false

  @doc "Whether the agent-format siblings (.md/.txt/.json/.xml) are served: live + geo?."
  def agent_visible?(%JobPosting{geo?: true} = posting), do: live?(posting)
  def agent_visible?(_), do: false

  @doc "The sitemap's indexable set — delegated to by `Vutuv.Sitemap` (never re-derived)."
  def indexable_query do
    today = BerlinTime.today()

    from(p in JobPosting,
      where:
        p.status == :published and is_nil(p.frozen_at) and p.seo? and
          p.visibility == :everyone and p.expires_on >= ^today
    )
  end

  # --- anti-abuse gate ------------------------------------------------------

  @doc """
  Whether `user` may publish (a new or the given) posting: a confirmed e-mail,
  an account at least #{@min_account_age_days} days old, and under the
  concurrent-publish caps. Returns `:ok | {:error, reason}`.
  """
  def publish_gate(%User{} = user, %JobPosting{} = posting) do
    cond do
      not user.email_confirmed? -> {:error, :email_unconfirmed}
      not account_old_enough?(user) -> {:error, :account_too_new}
      over_member_cap?(user, posting) -> {:error, :member_quota}
      over_organization_cap?(posting) -> {:error, :organization_quota}
      true -> :ok
    end
  end

  defp account_old_enough?(%User{inserted_at: inserted_at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :day) >= @min_account_age_days
  end

  # The posting itself doesn't count until it is published, so re-publishing an
  # already-published posting (an edit) never trips its own cap.
  defp over_member_cap?(%User{id: user_id}, %JobPosting{id: posting_id}) do
    JobPosting
    |> where([p], p.user_id == ^user_id and p.status == :published)
    |> exclude_self(posting_id)
    |> Repo.aggregate(:count, :id)
    |> Kernel.>=(max_published_per_member())
  end

  defp over_organization_cap?(%JobPosting{organization_id: nil}), do: false

  defp over_organization_cap?(%JobPosting{organization_id: org_id, id: posting_id}) do
    JobPosting
    |> where([p], p.organization_id == ^org_id and p.status == :published)
    |> exclude_self(posting_id)
    |> Repo.aggregate(:count, :id)
    |> Kernel.>=(max_published_per_organization())
  end

  # A not-yet-created posting (nil id) excludes nothing (Ecto forbids `id != nil`).
  defp exclude_self(query, nil), do: query
  defp exclude_self(query, posting_id), do: where(query, [p], p.id != ^posting_id)

  # --- create / update ------------------------------------------------------

  @doc """
  Creates a draft owned by `user`. `opts[:organization]` attributes it to a
  verified organization page — silently ignored unless `user` holds a role
  there, so the free-text `hiring_org_name` is the only employer shown for a
  personal posting.
  """
  def create_draft(%User{} = user, attrs, opts \\ []) do
    %JobPosting{user_id: user.id}
    |> JobPosting.changeset(attrs)
    |> put_organization(user, opts[:organization])
    |> put_tags(attrs)
    |> put_slug()
    |> Repo.insert()
    |> after_save(user, attrs)
  end

  @doc "Updates an existing posting (draft or live). Re-attaches tags and images."
  def update_posting(%JobPosting{} = posting, %User{} = user, attrs, opts \\ []) do
    posting
    |> Repo.preload(:job_posting_tags)
    |> JobPosting.changeset(attrs)
    |> put_organization(user, opts[:organization])
    |> put_tags(attrs)
    |> Repo.update()
    |> after_save(user, attrs)
  end

  @doc """
  Publishes `posting` with the latest `attrs`, running the publish-time
  validations (location, apply target, salary) and the anti-abuse gate. Stamps
  `first_published_at` once and `expires_on` = today + `runtime_days/0`.
  `opts[:organization]` re-attributes the posting (a role holder's choice);
  omitted, the stored attribution is kept.
  """
  def publish(%JobPosting{} = posting, %User{} = user, attrs \\ %{}, opts \\ []) do
    posting = Repo.preload(posting, :job_posting_tags)
    organization = Keyword.get(opts, :organization, organization_for(posting))

    changeset =
      posting
      |> JobPosting.publish_changeset(attrs)
      |> put_organization(user, organization)
      |> put_tags(attrs)

    with :ok <- validate_changeset(changeset),
         :ok <- publish_gate(user, Ecto.Changeset.apply_changes(changeset)) do
      today = BerlinTime.today()

      changeset
      |> Ecto.Changeset.put_change(:status, :published)
      |> Ecto.Changeset.put_change(:first_published_at, posting.first_published_at || now())
      |> Ecto.Changeset.put_change(:expires_on, Date.add(today, runtime_days()))
      |> Ecto.Changeset.put_change(:closed_at, nil)
      |> Ecto.Changeset.put_change(:close_reason, nil)
      |> put_slug()
      |> Repo.update()
      |> after_save(user, attrs)
      |> broadcast_updated()
    end
  end

  @doc "Closes a live posting with a reason (`:filled`/`:withdrawn`)."
  def close(%JobPosting{} = posting, reason) when reason in [:filled, :withdrawn] do
    posting
    |> JobPosting.status_changeset(:closed)
    |> Ecto.Changeset.put_change(:closed_at, now())
    |> Ecto.Changeset.put_change(:close_reason, reason)
    |> Repo.update()
    |> broadcast_updated()
  end

  @doc """
  Reposts an expired/closed posting: a brand-new draft copying the content
  (title, description, location, salary, apply, tags) with fresh dates and a new
  URL. The honest continuation — no bumping of the original's `datePosted`.
  """
  def repost(%JobPosting{} = posting, %User{} = user) do
    # Only the content is copied — narrower than a full show preload.
    posting = Repo.preload(posting, [:organization, job_posting_tags: :tag])

    attrs = %{
      "title" => posting.title,
      "hiring_org_name" => posting.hiring_org_name,
      "description" => posting.description,
      "employment_type" => posting.employment_type,
      "workplace_type" => posting.workplace_type,
      "street_address" => posting.street_address,
      "zip_code" => posting.zip_code,
      "city" => posting.city,
      "country" => posting.country,
      "remote_countries" => posting.remote_countries,
      "salary_min" => posting.salary_min,
      "salary_max" => posting.salary_max,
      "salary_currency" => posting.salary_currency,
      "salary_period" => posting.salary_period,
      "apply_kind" => posting.apply_kind,
      "apply_url" => posting.apply_url,
      "apply_email" => posting.apply_email,
      "language" => posting.language,
      "seo?" => posting.seo?,
      "geo?" => posting.geo?,
      "visibility" => posting.visibility,
      "required_tags" => tag_names(posting, :required),
      "nice_to_have_tags" => tag_names(posting, :nice_to_have)
    }

    create_draft(user, attrs, organization: posting.organization)
  end

  defp organization_for(%JobPosting{organization_id: nil}), do: nil

  defp organization_for(%JobPosting{organization_id: id}),
    do: Organizations.get_organization(id)

  # Only a role holder may attribute a posting to an organization page.
  defp put_organization(changeset, _user, nil),
    do: Ecto.Changeset.put_change(changeset, :organization_id, nil)

  defp put_organization(changeset, %User{} = user, %Organizations.Organization{} = organization) do
    if Organizations.can_manage?(organization, user),
      do: Ecto.Changeset.put_change(changeset, :organization_id, organization.id),
      else: Ecto.Changeset.put_change(changeset, :organization_id, nil)
  end

  defp put_slug(changeset) do
    case Ecto.Changeset.get_field(changeset, :slug) do
      nil ->
        title = Ecto.Changeset.get_field(changeset, :title) || "job"
        slug = Vutuv.SlugHelpers.gen_slug_unique(String.slice(title, 0, 120), JobPosting, :slug)
        Ecto.Changeset.put_change(changeset, :slug, slug)

      _existing ->
        changeset
    end
  end

  defp put_tags(changeset, attrs) do
    required = resolve_tag_ids(fetch(attrs, :required_tags))
    nice = resolve_tag_ids(fetch(attrs, :nice_to_have_tags)) -- required

    rows =
      Enum.map(required, &%JobPostingTag{tag_id: &1, priority: :required}) ++
        Enum.map(nice, &%JobPostingTag{tag_id: &1, priority: :nice_to_have})

    Ecto.Changeset.put_assoc(changeset, :job_posting_tags, rows)
  end

  # Resolve free-typed names to tag ids through the Tags chokepoints, honoring
  # the space/quote tokenizer and excluding honor tags (admin-only badges).
  defp resolve_tag_ids(value) do
    value
    |> Vutuv.Tags.parse_tag_names()
    |> Enum.map(&Tag.normalize_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.map(&tag_id_for/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tag_id_for(value) do
    case Tag.find_by_value(value) do
      %Tag{honor?: true} -> nil
      %Tag{id: id} -> id
      nil -> insert_tag(value)
    end
  end

  defp insert_tag(value) do
    case Repo.insert(Tag.changeset(%Tag{}, %{"value" => value})) do
      {:ok, tag} -> tag.id
      {:error, _} -> with(%Tag{id: id, honor?: false} <- Tag.find_by_value(value), do: id)
    end
  end

  defp fetch(attrs, key), do: attrs[key] || attrs[to_string(key)]

  # After a successful save, attach the composer's pending images and prune
  # removed ones, then reload the full page struct.
  defp after_save({:ok, %JobPosting{} = posting}, %User{} = user, attrs) do
    image_ids = fetch(attrs, :image_ids) || []
    attach_images(posting, user, image_ids)
    {:ok, preload_for_show(posting)}
  end

  defp after_save({:error, _} = error, _user, _attrs), do: error

  defp validate_changeset(changeset) do
    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  # --- view / apply counters ------------------------------------------------

  @doc "Increments the view counter (fire-and-forget)."
  def increment_view(%JobPosting{id: id}) do
    from(p in JobPosting, where: p.id == ^id) |> Repo.update_all(inc: [view_count: 1])
    :ok
  end

  @doc "Increments the apply-click counter (fire-and-forget)."
  def increment_apply_click(%JobPosting{id: id}) do
    from(p in JobPosting, where: p.id == ^id) |> Repo.update_all(inc: [apply_click_count: 1])
    :ok
  end

  # --- tags helpers ---------------------------------------------------------

  @doc "The posting's tags of a given priority, as `%{tag: tag}` join rows preloaded."
  def tags_of(%JobPosting{job_posting_tags: join_rows}, priority) when is_list(join_rows) do
    join_rows
    |> Enum.filter(&(&1.priority == priority))
    |> Enum.map(& &1.tag)
  end

  def tags_of(_, _), do: []

  @doc "The posting's tag names of a priority as a comma-joined string (for edit/repost)."
  def tag_names(posting, priority) do
    posting |> tags_of(priority) |> Enum.map_join(", ", & &1.name)
  end

  @doc """
  The slugs of `viewer`'s own profile tags that this posting also carries — the
  overlap the detail page highlights ("passt das zu mir?"). Empty for anon.
  """
  def matching_tag_slugs(%JobPosting{} = posting, %User{id: user_id}) do
    case posting |> all_tags() |> Enum.map(& &1.slug) do
      [] ->
        MapSet.new()

      slugs ->
        # Intersect in SQL, so a member with many profile tags only transfers the
        # handful that overlap this posting.
        Vutuv.Tags.Tag
        |> join(:inner, [t], ut in Vutuv.Tags.UserTag, on: ut.tag_id == t.id)
        |> where([t, ut], ut.user_id == ^user_id and t.slug in ^slugs)
        |> select([t], t.slug)
        |> Repo.all()
        |> MapSet.new()
    end
  end

  def matching_tag_slugs(_, _), do: MapSet.new()

  defp all_tags(%JobPosting{job_posting_tags: join_rows}) when is_list(join_rows),
    do: Enum.map(join_rows, & &1.tag)

  defp all_tags(_), do: []

  # --- images (post_images pattern) -----------------------------------------

  @doc "Creates a pending image (job_posting_id nil) from an upload, or `{:error, reason}`."
  def create_pending_image(%User{} = user, path, filename) do
    size = File.stat!(path).size

    if size > max_image_filesize() do
      {:error, :too_large}
    else
      token = JobPostingImage.gen_token()

      case Vutuv.JobPostingImageStore.store(path, filename, token) do
        {:ok, meta} ->
          %JobPostingImage{user_id: user.id, token: token}
          |> Ecto.Changeset.change(meta)
          |> Repo.insert()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update_image_alt(%JobPostingImage{} = image, alt) do
    image |> JobPostingImage.alt_changeset(%{"alt" => alt}) |> Repo.update()
  end

  def delete_pending_image(%JobPostingImage{job_posting_id: nil, token: token} = image) do
    Repo.delete(image)
    Vutuv.JobPostingImageStore.delete(token)
    :ok
  end

  def get_image_by_token(token) when is_binary(token) do
    JobPostingImage |> Repo.get_by(token: token) |> Repo.preload([:job_posting, :user])
  end

  def get_image_by_token(_), do: nil

  @doc "Pending images are visible to their uploader only; attached follow the posting."
  def image_visible_to?(%JobPostingImage{job_posting_id: nil, user_id: uploader_id}, viewer),
    do: viewer != nil and viewer.id == uploader_id

  def image_visible_to?(%JobPostingImage{job_posting: posting}, viewer),
    do: visible_to?(posting, viewer)

  # Attach the chosen pending images to the posting; delete + purge those the
  # editor removed.
  defp attach_images(%JobPosting{} = posting, %User{id: user_id}, keep_ids) do
    from(i in JobPostingImage,
      where: i.id in ^keep_ids and i.user_id == ^user_id and is_nil(i.job_posting_id)
    )
    |> Repo.update_all(set: [job_posting_id: posting.id])

    removed =
      from(i in JobPostingImage,
        where: i.job_posting_id == ^posting.id and i.id not in ^keep_ids,
        select: i.token
      )
      |> Repo.all()

    if removed != [] do
      from(i in JobPostingImage, where: i.job_posting_id == ^posting.id and i.id not in ^keep_ids)
      |> Repo.delete_all()

      Enum.each(removed, &Vutuv.JobPostingImageStore.delete/1)
    end

    :ok
  end

  @doc "Sweeps abandoned pending uploads older than `max_age_hours` (default 24)."
  def sweep_pending_images(max_age_hours \\ 24) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -max_age_hours * 3600, :second)

    tokens =
      from(i in JobPostingImage,
        where: is_nil(i.job_posting_id) and i.inserted_at < ^cutoff,
        select: i.token
      )
      |> Repo.all()

    from(i in JobPostingImage, where: is_nil(i.job_posting_id) and i.inserted_at < ^cutoff)
    |> Repo.delete_all()

    Enum.each(tokens, &Vutuv.JobPostingImageStore.delete/1)
    length(tokens)
  end

  # --- engagement (like + bookmark) -----------------------------------------

  def like_job_posting(%User{} = user, %JobPosting{} = posting),
    do: engage(JobPostingLike, :like, user, posting)

  def unlike_job_posting(%User{} = user, %JobPosting{} = posting),
    do: disengage(JobPostingLike, :like, user, posting)

  def bookmark_job_posting(%User{} = user, %JobPosting{} = posting),
    do: engage(JobPostingBookmark, :bookmark, user, posting)

  def unbookmark_job_posting(%User{} = user, %JobPosting{} = posting),
    do: disengage(JobPostingBookmark, :bookmark, user, posting)

  defp engage(schema, kind, %User{} = user, %JobPosting{} = posting) do
    case Engagement.insert_if_new(schema, %{user_id: user.id, job_posting_id: posting.id}, [
           :job_posting_id,
           :user_id
         ]) do
      :exists ->
        {:ok, :noop}

      {:inserted, row} ->
        broadcast_engagement(kind, user.id, posting.id, true)
        {:ok, row}
    end
  end

  defp disengage(schema, kind, %User{} = user, %JobPosting{} = posting) do
    {count, _} =
      Repo.delete_all(
        from(e in schema, where: e.job_posting_id == ^posting.id and e.user_id == ^user.id)
      )

    if count > 0, do: broadcast_engagement(kind, user.id, posting.id, false)
    :ok
  end

  @doc "Public like count plus the viewer's own flags for the action bar."
  def job_posting_engagement(%JobPosting{id: posting_id}, viewer) do
    viewer_id = viewer && viewer.id

    %{
      likes: like_count(posting_id),
      liked?: viewer_id != nil and engaged?(JobPostingLike, posting_id, viewer_id),
      bookmarked?: viewer_id != nil and engaged?(JobPostingBookmark, posting_id, viewer_id)
    }
  end

  defp like_count(posting_id) do
    Repo.aggregate(from(l in JobPostingLike, where: l.job_posting_id == ^posting_id), :count, :id)
  end

  defp engaged?(schema, posting_id, user_id) do
    Repo.exists?(
      from(e in schema, where: e.job_posting_id == ^posting_id and e.user_id == ^user_id)
    )
  end

  @doc "Subscribes to a posting's live counter topic."
  def subscribe(posting_id), do: Phoenix.PubSub.subscribe(Vutuv.PubSub, topic(posting_id))

  defp topic(posting_id), do: "job_posting:#{posting_id}"

  defp broadcast_engagement(kind, user_id, posting_id, active?) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      topic(posting_id),
      {:job_posting_counters, %{job_posting_id: posting_id, likes: like_count(posting_id)}}
    )

    Vutuv.Activity.broadcast(
      user_id,
      {:job_posting_engagement_changed,
       %{kind: kind, job_posting_id: posting_id, active?: active?}}
    )
  end

  defp broadcast_updated({:ok, %JobPosting{id: id}} = result) do
    Phoenix.PubSub.broadcast(
      Vutuv.PubSub,
      topic(id),
      {:job_posting_updated, %{job_posting_id: id}}
    )

    result
  end

  defp broadcast_updated(other), do: other

  @doc """
  One page of the member's liked / bookmarked postings for the `/bookmarks` hub.
  Returns `%{entries:, more?:, next_offset:}`.
  """
  def saved_job_postings_page(%User{id: user_id}, kind, opts) when kind in [:like, :bookmark] do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    schema = if kind == :like, do: JobPostingLike, else: JobPostingBookmark

    entries =
      from(p in JobPosting,
        join: e in ^schema,
        as: :engagement,
        on: e.job_posting_id == p.id,
        where: e.user_id == ^user_id and is_nil(p.frozen_at),
        order_by: [desc: e.inserted_at],
        limit: ^(limit + 1),
        offset: ^offset,
        preload: [:organization]
      )
      |> Repo.all()

    {shown, more?} =
      if length(entries) > limit, do: {Enum.take(entries, limit), true}, else: {entries, false}

    %{entries: shown, more?: more?, next_offset: offset + length(shown)}
  end

  # --- deletion / moderation ------------------------------------------------

  @doc """
  Deletes a posting: purges its image files (the DB cascade drops the rows and
  every like/bookmark) and settles any open moderation case.
  """
  def delete_job_posting(%JobPosting{} = posting) do
    tokens = image_tokens(posting.id)

    with {:ok, posting} <- Repo.delete(posting) do
      Vutuv.Moderation.content_deleted(posting)
      Enum.each(tokens, &Vutuv.JobPostingImageStore.delete/1)
      {:ok, posting}
    end
  end

  defp image_tokens(posting_id) do
    from(i in JobPostingImage, where: i.job_posting_id == ^posting_id, select: i.token)
    |> Repo.all()
  end

  @doc "Every image token a member owns (for the `Accounts.delete_user/1` on-disk purge)."
  def image_tokens_for_user(user_id) do
    from(i in JobPostingImage, where: i.user_id == ^user_id, select: i.token) |> Repo.all()
  end

  @doc "Whether the account has any postings (blocks organization hard-delete; #930 guard)."
  def any_for_organization?(organization_id) do
    Repo.exists?(from(p in JobPosting, where: p.organization_id == ^organization_id))
  end

  # --- sweeper support ------------------------------------------------------

  @doc "Postings that will expire on `date` (for the T-7-day reminder e-mail)."
  def postings_expiring_on(%Date{} = date) do
    from(p in JobPosting,
      where: p.status == :published and is_nil(p.frozen_at) and p.expires_on == ^date,
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Flips every overdue published posting to `expired`. Returns the count."
  def expire_overdue(%Date{} = today) do
    {count, _} =
      from(p in JobPosting, where: p.status == :published and p.expires_on < ^today)
      |> Repo.update_all(set: [status: :expired, updated_at: now()])

    count
  end

  # --- salary ---------------------------------------------------------------

  @doc "The yearly-equivalent of a pay figure, for cross-period comparison (#933/#935)."
  defdelegate yearly_equivalent(amount, period), to: Salary

  # --- misc -----------------------------------------------------------------

  defp now, do: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
end
