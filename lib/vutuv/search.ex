defmodule Vutuv.Search do
  @moduledoc """
  Member, tag and post search.

  `instant/2` powers the live search page: one call returns people (split
  into exact prefix matches and phonetically similar ones), tags and public
  posts. Queries support operators, parsed by `parse/2`: `vorname:`/`first:`
  and `nachname:`/`last:` search one name field, `tag:`/`skill:` only tags,
  `@handle` the username, and a fully quoted query (or `exact: true`) turns
  off prefix and phonetic matching. `record_query/2` persists a settled query
  for the search history. The original `search/2` stays as the low-level
  name/email matcher.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]
  import Vutuv.SearchText, only: [escape_like: 1]

  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Search.SearchQuery
  alias Vutuv.Search.SearchQueryRequester
  alias Vutuv.Search.SearchQueryResult

  @min_chars 3
  @min_field_chars 2
  @term_limit 100
  @people_limit 50
  @tag_limit 20
  @tag_scope_limit 50
  @post_limit 10
  @post_scope_limit 25

  # How long a settled search is kept (see prune_history/1). The search-history
  # tables feed no user-facing feature; the window just bounds their growth and
  # how long who-searched-what is retained. Change here to adjust the policy.
  @history_retention_days 90

  @email_regex ~r/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,4}$/

  # Operator keys (German first, English alias) → parsed field.
  @field_ops %{
    "tag" => :tag,
    "skill" => :tag,
    "vorname" => :first_name,
    "first" => :first_name,
    "nachname" => :last_name,
    "last" => :last_name,
    "ort" => :city,
    "stadt" => :city,
    "city" => :city
  }

  @scopes [:all, :people, :tags, :posts]

  @doc "Free-text queries shorter than this many characters return no results."
  def min_chars, do: @min_chars

  @doc "Whether the query looks like an email address (searched exactly)."
  def email?(value) when is_binary(value), do: Regex.match?(@email_regex, value)
  def email?(_value), do: false

  @doc """
  Parses a raw query into what to search where. Operators: `vorname:x` /
  `first:x` and `nachname:x` / `last:x` search a single name field, `@x` the
  username, and the people filters `tag:x` / `skill:x` (has that tag) and
  `ort:x` / `stadt:x` / `city:x` (has an address in that city) - both
  combinable with a name ("müller tag:php"). A query wrapped in double quotes
  sets `exact?` (equality instead of substring + phonetics). Options: `:scope`
  (`:all | :people | :tags | :posts`, the UI filter; operators override it)
  and `:exact` (the UI toggle, OR-ed with the quotes).
  """
  def parse(value, opts \\ []) when is_binary(value) do
    raw = value |> String.trim() |> String.downcase()
    {quoted?, unquoted} = strip_quotes(raw)

    {fields, words} =
      unquoted
      |> String.split()
      |> Enum.reduce({%{}, []}, fn token, {fields, words} ->
        case classify_token(token) do
          {:field, key, field_value} -> {Map.put(fields, key, field_value), words}
          :word -> {fields, [token | words]}
        end
      end)

    scope =
      if Enum.any?([:tag, :first_name, :last_name, :slug, :city], &fields[&1]) do
        :people
      else
        valid_scope(opts[:scope])
      end

    %{
      raw: raw,
      text: words |> Enum.reverse() |> Enum.join(" "),
      tag: fields[:tag],
      first_name: fields[:first_name],
      last_name: fields[:last_name],
      slug: fields[:slug],
      city: fields[:city],
      exact?: quoted? or opts[:exact] == true,
      scope: scope
    }
  end

  defp valid_scope(scope) when scope in @scopes, do: scope
  defp valid_scope(_scope), do: :all

  defp strip_quotes(value) do
    case Regex.run(~r/^"(.+)"$/s, value) do
      [_, inner] -> {true, String.trim(inner)}
      nil -> {false, value}
    end
  end

  defp classify_token("@" <> slug) when slug != "", do: {:field, :slug, slug}

  defp classify_token(token) do
    with [key, field_value] when field_value != "" <- String.split(token, ":", parts: 2),
         field when field != nil <- @field_ops[key] do
      {:field, field, field_value}
    else
      _ -> :word
    end
  end

  # An operator value is deliberate, so it may be shorter than free text.
  defp runnable?(parsed) do
    String.length(parsed.text) >= @min_chars or
      Enum.any?(
        [parsed.tag, parsed.first_name, parsed.last_name, parsed.slug, parsed.city],
        &(is_binary(&1) and String.length(&1) >= @min_field_chars)
      )
  end

  @doc """
  The search-as-you-type entry point. Returns `nil` for queries below the
  minimum length; otherwise a map with the normalized `:query`, the `:parsed`
  operator breakdown, the people split into `:exact_people` (literal substring
  matches) and `:similar_people` (matched only via Cologne/Soundex phonetics),
  matching
  `:tags` with `:tag_member_counts`, and public `:posts`. Accepts the same
  options as `parse/2`.
  """
  def instant(value, opts \\ [])

  def instant(value, opts) when is_binary(value) do
    parsed = parse(value, opts)

    if runnable?(parsed) do
      {exact, similar} = people(parsed)
      tags = tags(parsed)

      %{
        query: parsed.raw,
        parsed: parsed,
        exact_people: exact,
        similar_people: similar,
        tags: tags,
        tag_member_counts: tag_member_counts(tags),
        posts: posts(parsed)
      }
    end
  end

  def instant(_value, _opts), do: nil

  defp people(%{scope: scope}) when scope not in [:all, :people], do: {[], []}

  defp people(parsed) do
    cond do
      is_binary(parsed.slug) ->
        {parsed
         |> filtered_users()
         |> by_field(:username, parsed.slug, parsed.exact?)
         |> list_people(), []}

      is_binary(parsed.first_name) or is_binary(parsed.last_name) ->
        {people_by_name(parsed), []}

      # Pure filter search: "tag:php" / "ort:koblenz" without a name lists
      # everyone matching the filter(s).
      parsed.text == "" ->
        {people_by_filter(parsed), []}

      String.length(parsed.text) < @min_chars ->
        {[], []}

      email?(parsed.text) ->
        {search(parsed.text, true), []}

      parsed.exact? ->
        {exact_people(parsed), []}

      true ->
        substring_and_phonetic_people(parsed)
    end
  end

  defp people_by_name(parsed) do
    [first_name: parsed.first_name, last_name: parsed.last_name]
    |> Enum.filter(fn {_field, value} -> is_binary(value) end)
    |> Enum.reduce(filtered_users(parsed), fn {field, value}, query ->
      by_field(query, field, value, parsed.exact?)
    end)
    |> list_people()
  end

  defp people_by_filter(parsed) do
    if parsed.tag || parsed.city do
      parsed |> filtered_users() |> list_people()
    else
      []
    end
  end

  # The tag (tag:) and city (ort:) people filters, applied as EXISTS
  # subqueries against whatever query carries a named :user binding - the
  # users table for field searches, the search_terms join for name searches.
  defp filtered_users(parsed) do
    visible_users()
    |> filter_tag(parsed.tag, parsed.exact?)
    |> filter_city(parsed.city, parsed.exact?)
  end

  defp filter_tag(query, nil, _exact?), do: query

  defp filter_tag(query, tag, exact?) do
    sub =
      if exact? do
        from(ut in Vutuv.Tags.UserTag,
          join: t in assoc(ut, :tag),
          where:
            ut.user_id == parent_as(:user).id and
              (fragment("lower(?)", t.name) == ^tag or t.slug == ^tag)
        )
      else
        infix = "%" <> escape_like(tag) <> "%"

        from(ut in Vutuv.Tags.UserTag,
          join: t in assoc(ut, :tag),
          where:
            ut.user_id == parent_as(:user).id and
              (ilike(t.name, ^infix) or ilike(t.slug, ^infix))
        )
      end

    where(query, [], exists(subquery(sub)))
  end

  defp filter_city(query, nil, _exact?), do: query

  defp filter_city(query, city, exact?) do
    sub =
      if exact? do
        from(a in Vutuv.Profiles.Address,
          where: a.user_id == parent_as(:user).id and fragment("lower(?)", a.city) == ^city
        )
      else
        infix = "%" <> escape_like(city) <> "%"

        from(a in Vutuv.Profiles.Address,
          where: a.user_id == parent_as(:user).id and ilike(a.city, ^infix)
        )
      end

    where(query, [], exists(subquery(sub)))
  end

  # Field search (vorname:/nachname:/@handle) straight on the users table:
  # search terms only store combined names, so they cannot tell first from
  # last. Substring by default ("üller" finds Müller), equality when exact.
  defp by_field(query, field, value, true) do
    where(query, [user: u], fragment("lower(?)", field(u, ^field)) == ^value)
  end

  defp by_field(query, field, value, false) do
    where(query, [user: u], ilike(field(u, ^field), ^("%" <> escape_like(value) <> "%")))
  end

  defp list_people(query) do
    query
    |> order_by([user: u], asc: u.last_name, asc: u.first_name)
    |> limit(@people_limit)
    |> select([user: u], struct(u, ^people_fields()))
    |> Repo.all()
  end

  # The people results render through UserHTML.user_row (name parts, @handle,
  # avatar) plus work_information_map (headline fallback) and following_map (id),
  # so select only those columns instead of every wide user column per result.
  defp people_fields, do: [:headline | User.listing_fields()]

  # "Exact matches only" free text: the query must equal a real-name term
  # (first, last or a full-name combination) - no substring, no phonetics.
  defp exact_people(parsed) do
    from(t in SearchTerm,
      join: u in assoc(t, :user),
      as: :user,
      where:
        account_confirmed_row(u) and t.score == 100 and
          t.value == ^parsed.text,
      limit: @term_limit,
      select: struct(u, ^people_fields())
    )
    |> exclude_moderated()
    |> filter_tag(parsed.tag, parsed.exact?)
    |> filter_city(parsed.city, parsed.exact?)
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  # One pass over the search terms, then split per matched term: a score-100
  # term that literally contains the query ("üller" in "müller") is an exact
  # hit; everything else got in through the phonetic encodings and counts as
  # "similar". A user with any exact term never repeats in the similar group.
  defp substring_and_phonetic_people(parsed) do
    value = parsed.text

    terms =
      from(t in SearchTerm,
        join: u in assoc(t, :user),
        as: :user,
        order_by: [desc: t.score, asc: t.value],
        limit: @term_limit,
        select: %{score: t.score, value: t.value, user: struct(u, ^people_fields())}
      )
      |> phonetic_term_match(value)
      |> exclude_moderated()
      |> filter_tag(parsed.tag, parsed.exact?)
      |> filter_city(parsed.city, parsed.exact?)
      |> Repo.all()

    {exact_terms, similar_terms} =
      Enum.split_with(terms, &(&1.score == 100 and String.contains?(&1.value, value)))

    exact = exact_terms |> Enum.map(& &1.user) |> Enum.uniq_by(& &1.id)
    exact_ids = MapSet.new(exact, & &1.id)

    similar =
      similar_terms
      |> Enum.map(& &1.user)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(exact_ids, &1.id))

    {exact, similar}
  end

  defp visible_users do
    from(u in User, as: :user, where: account_confirmed_row(u))
    |> exclude_moderated()
  end

  # The shared substring + phonetic SearchTerm match behind both search entry
  # points: a confirmed user whose term matches `value` as a substring or by its
  # Cologne / Soundex encoding. The caller supplies the query (bound `[t, user:
  # u]`) and adds its own select / order / limit and the moderation/tag/city
  # filters; this computes the fuzzy values once and adds only the WHERE.
  defp phonetic_term_match(query, value) do
    cologne = phoneticize_search_value(value, :cologne)
    soundex = phoneticize_search_value(value, :soundex)
    infix = "%" <> escape_like(value) <> "%"

    from([t, user: u] in query,
      where:
        account_confirmed_row(u) and
          (like(t.value, ^infix) or ^cologne == t.value or ^soundex == t.value)
    )
  end

  defp tags(%{scope: scope}) when scope not in [:all, :tags], do: []

  defp tags(parsed) do
    case parsed.text do
      "" ->
        []

      needle ->
        limit = if parsed.scope == :tags, do: @tag_scope_limit, else: @tag_limit

        visible_tags(needle, parsed.exact?)
        |> order_by([t], asc: t.name)
        |> limit(^limit)
        |> Repo.all()
    end
  end

  defp visible_tags(needle, true) do
    from(t in Vutuv.Tags.Tag,
      where: fragment("lower(?)", t.name) == ^needle or t.slug == ^needle
    )
  end

  defp visible_tags(needle, false) do
    infix = "%" <> escape_like(needle) <> "%"
    from(t in Vutuv.Tags.Tag, where: ilike(t.name, ^infix) or ilike(t.slug, ^infix))
  end

  # How many members carry each found tag - the number that makes a tag chip
  # worth clicking.
  defp tag_member_counts([]), do: %{}

  defp tag_member_counts(tags) do
    ids = Enum.map(tags, & &1.id)

    # Count only members the tag page would actually show: activated and not
    # moderation-hidden (Tag.recommended_users applies the same gate), so the
    # chip's "N members" can't exceed what clicking it reveals.
    Repo.all(
      from(ut in Vutuv.Tags.UserTag,
        join: u in User,
        on: u.id == ut.user_id,
        where:
          ut.tag_id in ^ids and account_confirmed_row(u) and
            not account_hidden_row(u),
        group_by: ut.tag_id,
        select: {ut.tag_id, count(ut.id)}
      )
    )
    |> Map.new()
  end

  # Posts are matched by Postgres full-text search, which is word-exact
  # already; operators and the exact toggle do not apply to them.
  defp posts(%{scope: scope}) when scope not in [:all, :posts], do: []
  defp posts(%{text: text}) when byte_size(text) == 0, do: []

  defp posts(parsed) do
    limit = if parsed.scope == :posts, do: @post_scope_limit, else: @post_limit
    Vutuv.Posts.search_public(parsed.text, limit: limit)
  end

  @doc """
  Persists a settled query for the search history: the query row (reused
  case-insensitively), its current user results and one requester row per
  search (`requester` is the searching user or `nil` for visitors).
  """
  def record_query(value, requester) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    is_email = email?(value)

    results =
      if is_email do
        value |> search(true) |> Enum.map(&%SearchQueryResult{user_id: &1.id})
      else
        search(value, false)
      end

    params = %{"value" => value, "email?" => is_email}

    Repo.one(from(q in SearchQuery, where: q.value == ^value))
    |> insert_or_update_query(params, requester_changeset(requester), results)
  end

  @doc """
  Bounds the search-history tables, which are written on every settled search
  but read by no feature and never trimmed otherwise. Drops queries not searched
  within `@history_retention_days` (cascading their results and requesters
  through the FK), and trims requester rows older than the window from queries
  that are still active. Returns the deleted row counts. Run on a schedule by
  `Vutuv.Search.HistorySweeper`; safe to call by hand for an immediate sweep.
  """
  def prune_history(now \\ NaiveDateTime.utc_now()) do
    cutoff =
      now
      |> NaiveDateTime.add(-@history_retention_days * 24 * 3600, :second)
      |> NaiveDateTime.truncate(:second)

    # The per-search log (who searched what, when) grows with every search even
    # for a popular query whose row stays fresh, so trim its old rows directly.
    {requesters, _} =
      Repo.delete_all(from(r in SearchQueryRequester, where: r.inserted_at < ^cutoff))

    # Queries not searched within the window go entirely, taking their results
    # and any remaining requesters with them (FK on_delete: :delete_all).
    {queries, _} = Repo.delete_all(from(q in SearchQuery, where: q.updated_at < ^cutoff))

    %{search_queries: queries, search_query_requesters: requesters}
  end

  defp insert_or_update_query(nil, params, requester_changeset, results) do
    %SearchQuery{}
    |> SearchQuery.changeset(params)
    |> Ecto.Changeset.put_assoc(:search_query_requesters, [requester_changeset])
    |> Ecto.Changeset.put_assoc(:search_query_results, results)
    |> Repo.insert()
  end

  defp insert_or_update_query(query, params, requester_changeset, results) do
    requester_changeset =
      SearchQueryRequester.changeset(requester_changeset, %{search_query_id: query.id})

    query_changeset =
      query
      |> Repo.preload([:search_query_results, :search_query_requesters])
      |> SearchQuery.changeset(params)
      |> Ecto.Changeset.put_assoc(:search_query_results, results)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:search_query, query_changeset)
    |> Ecto.Multi.insert(:search_query_requester, requester_changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{search_query: query}} -> {:ok, query}
      {:error, _failed, changeset, _changes} -> {:error, changeset}
    end
  end

  defp requester_changeset(nil) do
    SearchQueryRequester.changeset(%SearchQueryRequester{}, %{user_id: nil})
  end

  defp requester_changeset(user), do: Ecto.build_assoc(user, :search_query_requesters)

  # Checks database for matches between search.value and search_terms
  def search(value, false) do
    for(
      term <-
        Repo.all(
          from(t in SearchTerm,
            left_join: u in assoc(t, :user),
            as: :user,
            # Only the two columns the result rows need — the full SearchTerm
            # row (value, timestamps) is never read here.
            select: %{score: t.score, user_id: t.user_id}
          )
          |> phonetic_term_match(String.downcase(value))
          |> exclude_moderated()
        )
    ) do
      %{
        score: term.score,
        result: %SearchQueryResult{
          user_id: term.user_id
        }
      }
    end
    # Sorts by score
    |> Enum.sort(&(&1.score > &2.score))
    # Filters duplicates
    |> Enum.uniq_by(& &1.result)
    # Maps to flat list of users
    |> Enum.map(& &1.result)
  end

  # Searches for the user with exactly that email address. Only addresses the
  # owner flagged public are findable (public? defaults to false): a private
  # address must not even confirm that an account exists.
  def search(value, true) do
    value = String.downcase(value)

    Repo.all(
      from(u in User,
        as: :user,
        join: e in assoc(u, :emails),
        where:
          account_confirmed_row(u) and ^value == e.value and
            e.public? == true
      )
      |> exclude_moderated()
    )
    # Filters duplicates
    |> Enum.uniq_by(& &1.id)
  end

  # Accounts in the moderation freezer (frozen pending review, suspended or
  # deactivated) are hidden everywhere, including search. The condition is
  # owned by Vutuv.Moderation.Query; left-joined orphan terms (no user) pass.
  defp exclude_moderated(query) do
    from([user: u] in query, where: not account_hidden_row(u))
  end

  defp phoneticize_search_value(value, algorithm) do
    # Split the value by non words
    for(section <- Regex.split(~r/[^a-z]+/, value, include_captures: true)) do
      phoneticize_section(section, algorithm)
    end
    # Recombine the search value with phoneticized words
    |> Enum.join()
  end

  defp phoneticize_section(section, algorithm) do
    if Regex.match?(~r/^[a-z]+$/, section) do
      # Phoneticize the words based on the algorithm parameter
      case algorithm do
        :cologne -> Vutuv.ColognePhonetics.to_cologne(section)
        :soundex -> Vutuv.Soundex.to_soundex(section)
      end
    else
      # Retain the non-words
      section
    end
  end
end
