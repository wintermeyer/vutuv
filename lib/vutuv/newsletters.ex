defmodule Vutuv.Newsletters do
  @moduledoc """
  Admin email newsletters ("Rundbrief"): compose and store a draft, send a test
  to a single address, broadcast to every eligible member, and keep a delivery
  log of when which email went out.

  The body is trusted Markdown with `{{merge}}` variables substituted per
  recipient (`Vutuv.Newsletters.Markdown`). Every message is built and sent
  through the one email chokepoint (`Vutuv.Notifications.Emailer`), so the bulk
  headers, bounce suppression and one-click unsubscribe all apply. Each send
  (test or broadcast) writes a `NewsletterDelivery` row — the protocol.
  """

  import Ecto.Query
  import Vutuv.SearchText, only: [escape_like: 1, normalize_search: 1]

  require Logger

  alias Ecto.Changeset
  alias Vutuv.Accounts
  alias Vutuv.Accounts.{Email, User}
  alias Vutuv.BerlinTime

  alias Vutuv.Newsletters.{
    Markdown,
    Newsletter,
    NewsletterClick,
    NewsletterDelivery,
    NewsletterGroup,
    NewsletterGroupMember
  }

  alias Vutuv.Notifications.Emailer
  alias Vutuv.Pages
  alias Vutuv.Profiles.Address
  alias Vutuv.Repo
  alias Vutuv.Tags.{Tag, UserTag}
  alias Vutuv.UUIDv7
  alias VutuvWeb.NewsletterToken
  alias VutuvWeb.UnsubscribeToken
  alias VutuvWeb.UserHelpers

  @email_re ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  ## Drafts (CRUD)

  @doc "All newsletters, newest first."
  def list_newsletters do
    Repo.all(from(n in Newsletter, order_by: [desc: n.inserted_at, desc: n.id]))
  end

  def get_newsletter(id), do: Repo.get(Newsletter, id)

  def get_newsletter!(id), do: Repo.get!(Newsletter, id)

  @doc "Creates a draft authored by `admin` (the author is set, never cast)."
  def create_newsletter(params, %User{} = admin) do
    %Newsletter{author_id: admin.id}
    |> Newsletter.changeset(params)
    |> Repo.insert()
  end

  def update_newsletter(%Newsletter{} = newsletter, params) do
    newsletter
    |> Newsletter.changeset(params)
    |> Repo.update()
  end

  def delete_newsletter(%Newsletter{} = newsletter), do: Repo.delete(newsletter)

  def change_newsletter(%Newsletter{} = newsletter, params \\ %{}) do
    Newsletter.changeset(newsletter, params)
  end

  ## Rendering / preview

  @doc """
  An admin-facing preview of the rendered newsletter, with the admin's own
  account data substituted for the merge variables, so the compose page can
  show what a recipient will see. Returns `%{subject, html}` (the inner content
  HTML, without the outer email chrome).
  """
  def preview(%Newsletter{} = newsletter, %User{} = admin) do
    subs = substitutions(admin, Accounts.first_email_value(admin) || "")

    content_html =
      newsletter.body |> Markdown.to_email_html() |> Markdown.apply_vars(subs, escape: true)

    %{
      subject: Markdown.apply_vars(newsletter.subject, subs),
      html: content_html
    }
  end

  @doc "The merge variables a newsletter may use (name + description)."
  def variables, do: Markdown.variables()

  @doc "The per-recipient substitution map for the merge variables."
  def substitutions(%User{} = user, email) do
    %{
      "greeting" => UserHelpers.email_greeting(user),
      "first_name" => user.first_name || "",
      "last_name" => user.last_name || "",
      "name" => UserHelpers.full_name(user),
      "username" => user.username || "",
      "email" => email
    }
  end

  ## Sending

  @doc """
  Sends a one-off test of `newsletter` to `email`, using `admin`'s account data
  for the merge variables (so the admin sees a realistic preview in their inbox,
  including the one-click unsubscribe link — which points at the admin's own
  newsletter switch). Logs the send as a `test` delivery. Returns
  `{:ok, delivery}` or `{:error, :invalid_email}`.
  """
  def deliver_test(%Newsletter{} = newsletter, email, %User{} = admin) when is_binary(email) do
    email = String.trim(email)

    if Regex.match?(@email_re, email) do
      content_html = Markdown.to_email_html(newsletter.body, track: true)
      unsubscribe_url = UnsubscribeToken.url(admin, :newsletter_emails?)

      delivery =
        send_and_log(newsletter, content_html, admin, email, "test", nil, unsubscribe_url)

      {:ok, delivery}
    else
      {:error, :invalid_email}
    end
  end

  @doc """
  Broadcasts `newsletter` once. With `group_id` nil it reaches every eligible
  member; with a group id it reaches that group's (snapshot) members who are
  still eligible. Atomically locks the draft (`draft -> sending`, recording the
  audience) so a double click cannot double-send, then runs the send in the
  background (inline in tests, where `:async_email` is false). Returns
  `{:ok, :started}` or `{:error, :already_sent}`.
  """
  def start_broadcast(%Newsletter{} = newsletter, group_id \\ nil) do
    case lock_for_sending(newsletter, group_id) do
      {:ok, locked} -> launch_broadcast(locked)
      :error -> {:error, :already_sent}
    end
  end

  @doc """
  Resumes a broadcast whose send task died mid-loop (a crash on one recipient,
  or a blue/green deploy stopping the slot): re-runs the send for every
  recipient who has no broadcast delivery row yet. Only a newsletter in
  `sending` can be resumed, and a compare-and-swap on `updated_at` ensures
  exactly one resumer wins even when two nodes sweep at once (the deploy
  overlap window). Returns `{:ok, :started}` or `{:error, :not_sending}`.
  """
  def resume_broadcast(%Newsletter{} = newsletter) do
    now = NaiveDateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(n in Newsletter,
          where:
            n.id == ^newsletter.id and n.status == "sending" and
              n.updated_at == ^newsletter.updated_at
        ),
        set: [updated_at: now]
      )

    if count == 1 do
      Newsletter |> Repo.get!(newsletter.id) |> launch_broadcast()
    else
      {:error, :not_sending}
    end
  end

  @stale_after_minutes 5

  @doc """
  Newsletters stuck mid-broadcast: status `sending` with no delivery activity
  for `minutes` (default #{@stale_after_minutes}). Activity is the latest
  broadcast delivery row, with `updated_at` covering a send that died before
  its first row. The staleness window is what makes the periodic resume safe
  during a blue/green deploy overlap: while the old slot is still actively
  sending, its rows are fresh and the new slot leaves the newsletter alone.
  """
  def stuck_newsletters(minutes \\ @stale_after_minutes) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -minutes * 60, :second)

    Repo.all(
      from(n in Newsletter,
        as: :newsletter,
        where: n.status == "sending",
        where: n.updated_at < ^cutoff,
        where:
          not exists(
            from(d in NewsletterDelivery,
              where:
                d.newsletter_id == parent_as(:newsletter).id and d.kind == "broadcast" and
                  d.inserted_at >= ^cutoff
            )
          )
      )
    )
  end

  # Runs the (idempotent) broadcast in the background - inline in tests, where
  # :async_email is false.
  defp launch_broadcast(%Newsletter{} = locked) do
    run = fn -> run_broadcast(locked) end

    if Application.get_env(:vutuv, :async_email, true) do
      {:ok, _pid} = Task.Supervisor.start_child(Vutuv.TaskSupervisor, run)
    else
      run.()
    end

    {:ok, :started}
  end

  @doc "The number of members a broadcast to everyone would reach right now."
  def eligible_count, do: audience_count(%{})

  ## Audiences / groups

  @doc "All groups, newest first (tag preloaded)."
  def list_groups do
    Repo.all(
      from(g in NewsletterGroup, order_by: [desc: g.inserted_at, desc: g.id], preload: [:tag])
    )
  end

  def get_group(id), do: NewsletterGroup |> Repo.get(id) |> preload_group()
  def get_group!(id), do: NewsletterGroup |> Repo.get!(id) |> preload_group()

  defp preload_group(nil), do: nil
  defp preload_group(%NewsletterGroup{} = group), do: Repo.preload(group, :tag)

  @doc "A blank changeset for the group builder (tag_name prefilled for editing)."
  def change_group(%NewsletterGroup{} = group, params \\ %{}) do
    group
    |> with_tag_name()
    |> NewsletterGroup.changeset(params)
  end

  @doc "Creates a group from filter params and immediately materializes its members."
  def create_group(params) do
    %NewsletterGroup{}
    |> NewsletterGroup.changeset(params)
    |> resolve_tag(params)
    |> Repo.insert()
    |> materialize_after_save()
  end

  @doc "Updates a group's filters and re-materializes its members."
  def update_group(%NewsletterGroup{} = group, params) do
    group
    |> NewsletterGroup.changeset(params)
    |> resolve_tag(params)
    |> Repo.update()
    |> materialize_after_save()
  end

  def delete_group(%NewsletterGroup{} = group), do: Repo.delete(group)

  # On a successful insert/update, freeze the matching members into the snapshot.
  defp materialize_after_save({:ok, group}), do: {:ok, materialize(group)}
  defp materialize_after_save(error), do: error

  # Sets the virtual tag_name from the (possibly preloaded) tag, for the edit form.
  defp with_tag_name(%NewsletterGroup{} = group) do
    %{group | tag_name: tag_name_of(group)}
  end

  defp tag_name_of(%NewsletterGroup{tag: %Tag{name: name}}), do: name
  defp tag_name_of(%NewsletterGroup{tag_id: nil}), do: nil

  defp tag_name_of(%NewsletterGroup{tag_id: id}),
    do: Repo.one(from(t in Tag, where: t.id == ^id, select: t.name))

  # Resolves the typed tag_name to a tag_id (or an error when no tag matches).
  defp resolve_tag(changeset, params) do
    case params |> Map.get("tag_name", Map.get(params, :tag_name)) |> normalize_search() do
      nil ->
        Changeset.put_change(changeset, :tag_id, nil)

      name ->
        case find_tag(name) do
          nil -> Changeset.add_error(changeset, :tag_name, "no tag with that name")
          %Tag{} = tag -> Changeset.put_change(changeset, :tag_id, tag.id)
        end
    end
  end

  @doc "Finds a tag by exact (case-insensitive) name, or nil."
  def find_tag(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        nil

      trimmed ->
        Repo.one(
          from(t in Tag, where: fragment("lower(?) = lower(?)", t.name, ^trimmed), limit: 1)
        )
    end
  end

  def find_tag(_name), do: nil

  @doc "The distinct, non-blank country values present on member addresses, sorted."
  def country_options do
    Repo.all(
      from(a in Address,
        where: not is_nil(a.country) and a.country != "",
        distinct: true,
        order_by: a.country,
        select: a.country
      )
    )
  end

  @doc """
  How many members match a filter `criteria` map right now (before any cap).
  Keys: `:locales`, `:country`, `:min_age`, `:max_age`, `:tag_id`,
  `:excluded_group_ids` (all optional). This is the live "how many are caught"
  count for the builder.
  """
  def audience_count(criteria) do
    Repo.one(from(u in audience_query(criteria), select: count(u.id)))
  end

  @doc """
  The matching member ids, optionally capped at `limit`. With `random?` true the
  cap takes a random sample of the pool; otherwise the oldest by creation time
  (`inserted_at`). Order only matters when capped — the snapshot is a set.
  """
  def audience_user_ids(criteria, limit \\ nil, random? \\ false) do
    query =
      criteria
      |> audience_query()
      |> order_audience(random?)
      |> select([u], u.id)

    query = if is_integer(limit) and limit > 0, do: from(u in query, limit: ^limit), else: query
    Repo.all(query)
  end

  defp order_audience(query, true), do: from(u in query, order_by: fragment("random()"))

  defp order_audience(query, _false),
    do: from(u in query, order_by: [asc: u.inserted_at, asc: u.id])

  @preview_limit 24
  @members_per_page 100

  @doc "How many matching members the live builder previews."
  def preview_limit, do: @preview_limit

  @doc "The page size for a group's member list on the show page."
  def members_per_page, do: @members_per_page

  @doc """
  One page of the matching members (oldest first) for the live builder preview —
  enough to eyeball whether the filters are right. `opts` may carry `:page`
  (1-based) and `:per_page` (default `preview_limit/0`). Returns user rows with
  `User.listing_fields/0` (name, slug, avatar), so they can link to profiles.
  """
  def audience_preview(criteria, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @preview_limit)
    page = max(Keyword.get(opts, :page, 1), 1)

    criteria
    |> audience_query()
    |> order_by([u], asc: u.inserted_at, asc: u.id)
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> select([u], struct(u, ^User.listing_fields()))
    |> Repo.all()
  end

  @doc """
  Eligible members whose handle matches `pattern` (same `*`/`?`/contains rules as
  the username filter), paginated — the list the admin searches to pick specific
  accounts to include/exclude. Independent of the audience, so any eligible
  member can be found and added.
  """
  def search_members(pattern, opts \\ []) when is_binary(pattern) do
    per_page = Keyword.get(opts, :per_page, @preview_limit)
    page = max(Keyword.get(opts, :page, 1), 1)

    pattern
    |> member_search_query()
    |> order_by([u], asc: u.username)
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> select([u], struct(u, ^User.listing_fields()))
    |> Repo.all()
  end

  @doc "How many eligible members match the `search_members/2` pattern."
  def search_members_count(pattern) when is_binary(pattern) do
    Repo.aggregate(member_search_query(pattern), :count)
  end

  @doc "Every eligible member id matching `pattern` (unpaged) — for select-all."
  def search_member_ids(pattern) when is_binary(pattern) do
    pattern |> member_search_query() |> select([u], u.id) |> Repo.all()
  end

  defp member_search_query(pattern) do
    now = NaiveDateTime.utc_now(:second)

    now
    |> eligible_users()
    |> where(
      [u],
      exists(
        from(e in Email, where: e.user_id == parent_as(:u).id and is_nil(e.undeliverable_at))
      )
    )
    |> where([u], ilike(u.username, ^username_like(pattern)))
  end

  @doc """
  Of `user_ids`, the ones that are in the final audience for `criteria` — i.e.
  which checkboxes should be ticked when curating from a member list.
  """
  def audience_member_ids(criteria, user_ids) when is_list(user_ids) do
    from(u in audience_query(criteria), where: u.id in ^user_ids, select: u.id) |> Repo.all()
  end

  @doc "Resolves the given user ids to profile-linkable rows (e.g. the excluded chips)."
  def users_by_ids([]), do: []

  def users_by_ids(ids) when is_list(ids) do
    Repo.all(from(u in User, where: u.id in ^ids, select: struct(u, ^User.listing_fields())))
  end

  @doc "The exact number of frozen members in a group's snapshot."
  def group_member_count(%NewsletterGroup{id: id}) do
    Repo.aggregate(from(m in NewsletterGroupMember, where: m.group_id == ^id), :count)
  end

  @doc """
  One page of a group's frozen members (oldest first), as profile-linkable user
  rows (`User.listing_fields/0`). Paginated with `Vutuv.Pages` at
  `members_per_page/0`.
  """
  def list_group_members(%NewsletterGroup{} = group, params \\ %{}) do
    total = group_member_count(group)

    from(m in NewsletterGroupMember,
      where: m.group_id == ^group.id,
      join: u in assoc(m, :user),
      order_by: [asc: u.inserted_at, asc: u.id],
      select: struct(u, ^User.listing_fields())
    )
    |> Pages.paginate(params, total, @members_per_page)
    |> Repo.all()
  end

  @doc "How many of a group's snapshot members are still reachable (for the audience picker)."
  def group_reach_count(group_id) do
    now = NaiveDateTime.utc_now(:second)

    Repo.one(
      from(u in eligible_users(now),
        join: m in NewsletterGroupMember,
        on: m.user_id == u.id and m.group_id == ^group_id,
        where:
          exists(
            from(e in Email, where: e.user_id == parent_as(:u).id and is_nil(e.undeliverable_at))
          ),
        select: count(u.id)
      )
    )
  end

  @doc """
  How many members a broadcast to `group_id` would reach right now (the
  confirmation count): the whole eligible base for `nil`, else the group's
  still-reachable snapshot.
  """
  def broadcast_reach(nil), do: eligible_count()
  def broadcast_reach(group_id), do: group_reach_count(group_id)

  @doc "How many broadcast emails have already gone out for `newsletter` (live progress)."
  def broadcast_sent_count(%Newsletter{} = newsletter) do
    count_deliveries(newsletter, %{kind: "broadcast"})
  end

  # Freezes the matching members (filters minus exclusions, capped) into the
  # group's snapshot, replacing any previous membership, and caches the count.
  defp materialize(%NewsletterGroup{} = group) do
    ids = audience_user_ids(criteria_from_group(group), group.max_size, group.random_sample)
    now = NaiveDateTime.utc_now(:second)

    # insert_all does not run the schema's UUID v7 autogenerate, so mint ids here.
    rows =
      Enum.map(ids, fn user_id ->
        %{
          id: UUIDv7.generate(),
          group_id: group.id,
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(m in NewsletterGroupMember, where: m.group_id == ^group.id))
        Repo.insert_all(NewsletterGroupMember, rows)

        Repo.update_all(from(g in NewsletterGroup, where: g.id == ^group.id),
          set: [member_count: length(ids), updated_at: now]
        )
      end)

    %{group | member_count: length(ids)}
  end

  defp criteria_from_group(%NewsletterGroup{} = group) do
    %{
      locales: group.locales,
      country: group.country,
      min_age: group.min_age,
      max_age: group.max_age,
      tag_id: group.tag_id,
      username: group.username,
      included_group_ids: group.included_group_ids,
      excluded_group_ids: group.excluded_group_ids,
      included_user_ids: group.included_user_ids,
      excluded_user_ids: group.excluded_user_ids
    }
  end

  # The eligible-member query (as :u) narrowed by the filter criteria, used for
  # the live count/preview and the snapshot materialization. Membership is:
  # eligible AND ((all filters match) OR in an *added* group OR an *added*
  # account) AND NOT in a *subtracted* group AND NOT a *subtracted* account.
  # The filter clauses are combined as one dynamic so they can be OR-ed with the
  # additions.
  defp audience_query(criteria) do
    now = NaiveDateTime.utc_now(:second)
    today = BerlinTime.today()

    base =
      now
      |> eligible_users()
      |> where(
        [u],
        exists(
          from(e in Email, where: e.user_id == parent_as(:u).id and is_nil(e.undeliverable_at))
        )
      )

    base
    |> where(^membership(criteria, today))
    |> exclude_groups(present_ids(criteria, :excluded_group_ids))
    |> exclude_users(present_ids(criteria, :excluded_user_ids))
  end

  defp present_ids(criteria, key) do
    criteria |> Map.get(key) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
  end

  # The "is in this audience" predicate. A member belongs when they match the
  # filters, are in an *added* group, or are an *added* account - the three
  # positive selectors, OR-ed together. With *no* positive selector at all the
  # audience is everyone (the "all members" group and the "send to the rest"
  # group both rely on this); but the moment any positive selector is present
  # the audience is exactly the union of those, so a hand-picked account list
  # resolves to just those accounts rather than everyone-plus-them. (An empty
  # filter must therefore contribute *nothing* here, not vacuously match all.)
  defp membership(criteria, today) do
    [
      filter_predicate(criteria, today),
      included_groups_clause(present_ids(criteria, :included_group_ids)),
      included_users_clause(present_ids(criteria, :included_user_ids))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> dynamic(true)
      clauses -> Enum.reduce(clauses, fn clause, acc -> dynamic(^acc or ^clause) end)
    end
  end

  defp included_groups_clause([]), do: nil
  defp included_groups_clause(ids), do: dynamic([u], u.id in subquery(group_member_ids(ids)))

  defp included_users_clause([]), do: nil
  defp included_users_clause(ids), do: dynamic([u], u.id in ^ids)

  defp group_member_ids(ids) do
    from(m in NewsletterGroupMember, where: m.group_id in ^ids, select: m.user_id)
  end

  # The AND-combined filter clauses, or nil when no filter criterion is set (so
  # an empty filter contributes nobody to `membership/2` rather than everybody).
  defp filter_predicate(criteria, today) do
    [
      locale_predicate(Map.get(criteria, :locales)),
      country_predicate(Map.get(criteria, :country)),
      min_age_predicate(Map.get(criteria, :min_age), today),
      max_age_predicate(Map.get(criteria, :max_age), today),
      tag_predicate(Map.get(criteria, :tag_id)),
      username_predicate(Map.get(criteria, :username))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      predicates -> Enum.reduce(predicates, fn predicate, acc -> dynamic(^acc and ^predicate) end)
    end
  end

  defp locale_predicate(locales) when is_list(locales) and locales != [],
    do: dynamic([u], u.locale in ^locales)

  defp locale_predicate(_locales), do: nil

  defp country_predicate(country) when is_binary(country) and country != "" do
    dynamic(
      [u],
      exists(from(a in Address, where: a.user_id == parent_as(:u).id and a.country == ^country))
    )
  end

  defp country_predicate(_country), do: nil

  defp min_age_predicate(min_age, today) when is_integer(min_age) do
    # age >= min_age  <=>  born on or before (today shifted back min_age years)
    latest = shift_years(today, -min_age)
    dynamic([u], not is_nil(u.birthdate) and u.birthdate <= ^latest)
  end

  defp min_age_predicate(_min_age, _today), do: nil

  defp max_age_predicate(max_age, today) when is_integer(max_age) do
    # age <= max_age  <=>  born on or after ((today shifted back max_age+1 years) + 1 day)
    earliest = today |> shift_years(-(max_age + 1)) |> Date.add(1)
    dynamic([u], not is_nil(u.birthdate) and u.birthdate >= ^earliest)
  end

  defp max_age_predicate(_max_age, _today), do: nil

  defp tag_predicate(tag_id) when is_binary(tag_id) do
    dynamic(
      [u],
      exists(from(ut in UserTag, where: ut.user_id == parent_as(:u).id and ut.tag_id == ^tag_id))
    )
  end

  defp tag_predicate(_tag_id), do: nil

  defp username_predicate(pattern) when is_binary(pattern) and pattern != "" do
    dynamic([u], ilike(u.username, ^username_like(pattern)))
  end

  defp username_predicate(_pattern), do: nil

  # Turns an admin's handle pattern into an ILIKE pattern: real `%`/`_`/`\` are
  # escaped, `*`/`?` become the SQL wildcards. A pattern the admin gave *no*
  # wildcard in is wrapped as a contains match (so "meyer" finds
  # "stefan.wintermeyer"); the wildcard check is on the raw input, so an escaped
  # literal `_` doesn't look like a wildcard.
  defp username_like(pattern) do
    escaped = escape_like(pattern)

    if String.contains?(pattern, ["*", "?"]) do
      escaped |> String.replace("*", "%") |> String.replace("?", "_")
    else
      "%" <> escaped <> "%"
    end
  end

  defp exclude_groups(query, []), do: query

  defp exclude_groups(query, ids) do
    from(u in query, where: u.id not in subquery(group_member_ids(ids)))
  end

  defp exclude_users(query, []), do: query
  defp exclude_users(query, ids), do: from(u in query, where: u.id not in ^ids)

  # Shifts a date by whole years, clamping Feb 29 to Feb 28 in a non-leap target.
  defp shift_years(%Date{year: year, month: month, day: day}, years) do
    case Date.new(year + years, month, day) do
      {:ok, date} -> date
      {:error, _invalid} -> Date.new!(year + years, month, 28)
    end
  end

  @deliveries_per_page 50

  # The sortable columns of the delivery log, by the `?sort=` value a header
  # link sets. "recipient" sorts by the address (always present, unlike a
  # member who is nil for a test send).
  @sort_columns %{
    "when" => :inserted_at,
    "kind" => :kind,
    "recipient" => :email,
    "status" => :status
  }

  @doc "The default delivery-log page size."
  def deliveries_per_page, do: @deliveries_per_page

  @doc "The sortable delivery-log columns (the `?sort=` values)."
  def delivery_sort_columns, do: Map.keys(@sort_columns)

  @doc """
  Normalizes raw request params into a validated filter map for the delivery
  log: `kind`/`status` (only known values pass), `q` (search term, trimmed),
  `sort` (a known column, default "when") and `dir` ("asc"/"desc", default
  "desc"). Anything invalid falls back to a safe default, so the params can
  never inject a column or value into the query.
  """
  def delivery_filters(params) when is_map(params) do
    %{
      kind: validated(params["kind"], NewsletterDelivery.kinds()),
      status: validated(params["status"], NewsletterDelivery.statuses()),
      q: normalize_search(params["q"]),
      sort: validated(params["sort"], delivery_sort_columns()) || "when",
      dir: if(params["dir"] == "asc", do: "asc", else: "desc")
    }
  end

  @doc "How many deliveries match the filters (for the pager)."
  def count_deliveries(%Newsletter{} = newsletter, filters \\ %{}) do
    newsletter |> deliveries_base(filters) |> Repo.aggregate(:count)
  end

  @doc """
  One page of the delivery log, filtered, searched, sorted and paginated
  (recipient member preloaded). `opts` may carry `:total` (skip the recount)
  and `:per_page` (default `deliveries_per_page/0`).
  """
  def list_deliveries(%Newsletter{} = newsletter, filters \\ %{}, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @deliveries_per_page)
    total = Keyword.get(opts, :total) || count_deliveries(newsletter, filters)

    newsletter
    |> deliveries_base(filters)
    |> order_deliveries(filters)
    |> preload([:user])
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  defp deliveries_base(%Newsletter{id: id}, filters) do
    from(d in NewsletterDelivery, where: d.newsletter_id == ^id)
    |> filter_field(:kind, Map.get(filters, :kind))
    |> filter_field(:status, Map.get(filters, :status))
    |> search_recipient(Map.get(filters, :q))
  end

  defp filter_field(query, _field, value) when value in [nil, ""], do: query

  defp filter_field(query, field, value) do
    from(d in query, where: field(d, ^field) == ^value)
  end

  defp search_recipient(query, value) when value in [nil, ""], do: query

  defp search_recipient(query, value) do
    like = "%" <> escape_like(value) <> "%"

    from(d in query,
      left_join: u in assoc(d, :user),
      where: ilike(d.email, ^like) or ilike(u.username, ^like)
    )
  end

  defp order_deliveries(query, filters) do
    column = Map.get(@sort_columns, Map.get(filters, :sort), :inserted_at)
    dir = if Map.get(filters, :dir) == "asc", do: :asc, else: :desc
    from(d in query, order_by: [{^dir, field(d, ^column)}, {^dir, d.id}])
  end

  defp validated(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: nil)

  defp validated(_value, _allowed), do: nil

  ## Click tracking (the success overview)

  @clicks_per_page 50
  @max_url 255

  @doc "The click-log page size, shared by the query and the pager."
  def clicks_per_page, do: @clicks_per_page

  @doc """
  Records that the recipient identified by `user_id` followed the tracked link
  `url` in newsletter `newsletter_id` (the "when" is the row's `inserted_at`).
  Best-effort: a stale link whose newsletter or member is gone is ignored rather
  than 500ing the visitor's navigation. Returns `:ok` or `:error`.
  """
  def record_click(newsletter_id, user_id, url)
      when is_binary(newsletter_id) and is_binary(user_id) and is_binary(url) do
    Repo.insert!(%NewsletterClick{
      newsletter_id: newsletter_id,
      user_id: user_id,
      url: String.slice(url, 0, @max_url)
    })

    :ok
  rescue
    Ecto.ConstraintError -> :error
  end

  @doc """
  The headline success numbers for `newsletter`, over the clicks by members it
  was actually broadcast to (test clicks are excluded): how many recipients, how
  many distinct members clicked, the total clicks, and the click rate in percent.
  """
  def newsletter_stats(%Newsletter{} = newsletter) do
    %{clicks: clicks, clickers: clickers} =
      Repo.one(
        from(c in broadcast_clicks_query(newsletter.id),
          select: %{clicks: count(c.id), clickers: count(c.user_id, :distinct)}
        )
      )

    %{
      recipients: newsletter.recipient_count,
      total_clicks: clicks,
      unique_clickers: clickers,
      click_rate: click_rate(clickers, newsletter.recipient_count)
    }
  end

  @doc """
  Per-link tally for `newsletter` (broadcast clicks only), most-clicked first:
  the link `url`, the total `clicks`, and the distinct `clickers`.
  """
  def link_stats(%Newsletter{} = newsletter) do
    newsletter.id
    |> broadcast_clicks_query()
    |> group_by([c], c.url)
    |> select([c], %{url: c.url, clicks: count(c.id), clickers: count(c.user_id, :distinct)})
    |> order_by([c], desc: count(c.id), asc: c.url)
    |> Repo.all()
  end

  @doc "How many broadcast clicks `newsletter` has (for the click-log pager)."
  def count_clicks(%Newsletter{} = newsletter),
    do: Repo.aggregate(broadcast_clicks_query(newsletter.id), :count)

  @doc """
  One page of `newsletter`'s broadcast click log, newest first, with the member
  preloaded. `opts` may carry `:total` (skip the recount) and `:per_page`.
  """
  def list_clicks(%Newsletter{} = newsletter, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @clicks_per_page)
    total = Keyword.get(opts, :total) || count_clicks(newsletter)

    newsletter.id
    |> broadcast_clicks_query()
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> preload([:user])
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
  end

  # A newsletter's clicks restricted to members it was broadcast to: the inner
  # join to a "broadcast" delivery for the same (newsletter, member) drops test
  # clicks and clicks whose member was since deleted (nilified user_id). One
  # broadcast delivery exists per recipient, so the join never fans a click out.
  defp broadcast_clicks_query(newsletter_id) do
    from(c in NewsletterClick,
      join: d in NewsletterDelivery,
      on:
        d.newsletter_id == c.newsletter_id and d.user_id == c.user_id and
          d.kind == "broadcast",
      where: c.newsletter_id == ^newsletter_id
    )
  end

  defp click_rate(_clickers, recipients) when recipients in [nil, 0], do: 0.0
  defp click_rate(clickers, recipients), do: clickers / recipients * 100

  # Flips the draft to "sending" only if it is still a draft (recording the
  # chosen audience), so exactly one caller wins the broadcast (update_all
  # reports how many rows it changed).
  defp lock_for_sending(%Newsletter{id: id}, group_id) do
    now = NaiveDateTime.utc_now(:second)

    {count, _} =
      Repo.update_all(
        from(n in Newsletter, where: n.id == ^id and n.status == "draft"),
        set: [status: "sending", group_id: group_id, updated_at: now]
      )

    if count == 1, do: {:ok, Repo.get!(Newsletter, id)}, else: :error
  end

  defp run_broadcast(%Newsletter{} = newsletter) do
    content_html = Markdown.to_email_html(newsletter.body, track: true)
    now = NaiveDateTime.utc_now(:second)

    now
    |> recipient_query(newsletter)
    |> Repo.all()
    |> Enum.each(fn {user, email} ->
      send_and_log(
        newsletter,
        content_html,
        user,
        email,
        "broadcast",
        user.id,
        UnsubscribeToken.url(user, :newsletter_emails?)
      )
    end)

    # Count the whole protocol, not this run: after a resume the tally must
    # cover the rows the original (crashed) send already wrote.
    count = count_deliveries(newsletter, %{kind: "broadcast"})

    Repo.update_all(
      from(n in Newsletter, where: n.id == ^newsletter.id),
      set: [status: "sent", sent_at: now, recipient_count: count, updated_at: now]
    )

    {:ok, count}
  end

  # Sends one recipient's email and records the outcome in the delivery log.
  # The address is trimmed and validated first: the legacy import left ~950
  # addresses with whitespace in them, and one such address must cost one
  # "invalid" row, never the rest of the broadcast.
  defp send_and_log(
         newsletter,
         content_html,
         subs_user,
         to_email,
         kind,
         log_user_id,
         unsubscribe_url
       ) do
    to_email = String.trim(to_email)

    status =
      if Regex.match?(@email_re, to_email) do
        deliver_one(newsletter, content_html, subs_user, to_email, unsubscribe_url)
      else
        "invalid"
      end

    Repo.insert!(%NewsletterDelivery{
      newsletter_id: newsletter.id,
      user_id: log_user_id,
      email: to_email,
      kind: kind,
      status: status
    })
  end

  # Builds the email from the prepared content (rendered once, variables
  # substituted per recipient) and sends it through the chokepoint. Any crash
  # becomes an "error" status instead of killing the whole broadcast loop: a
  # single address with a space in its domain once took down a 2,424-recipient
  # send, because the SMTP adapter's puny-encoding raises on such input.
  defp deliver_one(newsletter, content_html, subs_user, to_email, unsubscribe_url) do
    subs = substitutions(subs_user, to_email)
    click_token = NewsletterToken.sign(newsletter, subs_user)

    %{
      to_name: UserHelpers.name_for_email_to_field(subs_user),
      to_email: to_email,
      subject: Markdown.apply_vars(newsletter.subject, subs),
      locale: email_locale(subs_user),
      content_html:
        content_html
        |> Markdown.apply_vars(subs, escape: true)
        |> Markdown.put_click_token(click_token),
      content_text: Markdown.apply_vars(newsletter.body, subs),
      unsubscribe_url: unsubscribe_url
    }
    |> Emailer.newsletter_email()
    |> Emailer.deliver()
    |> delivery_status()
  rescue
    exception ->
      Logger.error(
        "Newsletter #{newsletter.id} delivery to #{to_email} crashed: " <>
          Exception.message(exception)
      )

      "error"
  catch
    kind, reason ->
      Logger.error(
        "Newsletter #{newsletter.id} delivery to #{to_email} #{kind}: #{inspect(reason)}"
      )

      "error"
  end

  defp delivery_status({:ok, _email}), do: "sent"
  defp delivery_status(:suppressed), do: "suppressed"
  defp delivery_status(_other), do: "error"

  # Only en/de newsletter templates exist, so collapse every other locale to en.
  defp email_locale(%{locale: "de"}), do: "de"
  defp email_locale(_user), do: "en"

  # Confirmed, reachable, not-suspended, not-deactivated members who have not
  # opted out of the newsletter. Named binding :u so eligible_count/0 can attach
  # an EXISTS on a deliverable address without re-stating the filters.
  defp eligible_users(now) do
    from(u in User,
      as: :u,
      where: u.email_confirmed? == true,
      where: u.newsletter_emails? == true,
      where: is_nil(u.deactivated_at),
      where: is_nil(u.unreachable_at),
      where: is_nil(u.suspended_until) or u.suspended_until < ^now
    )
  end

  # One {user, address} per eligible member: their lowest-position deliverable
  # email (DISTINCT ON the user, ordered by position). Bounced addresses are
  # skipped by the join; if every address bounced the member is unreachable_at
  # and already filtered out above. With a `group_id`, narrowed to that group's
  # (snapshot) members — who must still be eligible right now. Members who
  # already have a broadcast delivery row are excluded, which makes the
  # broadcast idempotent: a resume after a mid-send crash mails only the rest.
  defp recipient_query(now, %Newsletter{id: newsletter_id, group_id: group_id}) do
    base =
      from(u in eligible_users(now),
        join: e in Email,
        on: e.user_id == u.id and is_nil(e.undeliverable_at),
        where:
          not exists(
            from(d in NewsletterDelivery,
              where:
                d.newsletter_id == ^newsletter_id and d.user_id == parent_as(:u).id and
                  d.kind == "broadcast"
            )
          ),
        distinct: u.id,
        order_by: [asc: u.id, asc: e.position],
        select: {u, e.value}
      )

    case group_id do
      nil ->
        base

      id ->
        from([u, e] in base,
          join: m in NewsletterGroupMember,
          on: m.user_id == u.id and m.group_id == ^id
        )
    end
  end
end
