defmodule Vutuv.Search do
  @moduledoc """
  Member, organization, tag and post search.

  `page/2` powers the live search page: people (split into exact prefix
  matches and phonetically similar ones, plus the people whose CV names a
  matching employer or school), public organization pages, tags and public
  posts, each kind with its total, so the page can preview a few of every kind
  and page through one. `instant/2` is the plain matcher the Mastodon API
  reads. Queries support operators, parsed by
  `parse/2`: `vorname:`/`first:` and `nachname:`/`last:` search one name
  field, `tag:`/`skill:` filters both people and posts carrying that tag
  (issue #946), `@handle` the username, and a fully quoted query (or
  `exact: true`) turns off prefix and phonetic matching.
  `search_by_email/1` stays as the low-level email matcher.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [contains: 1, equals: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.SearchTerm
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.SearchText
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag

  @min_chars 3
  @min_field_chars 2
  # How many search terms and people one query loads. The search page's people
  # scope pages through its name matches in memory, so it gets the larger pair;
  # everything else (the "All" preview, the Mastodon API) keeps the smaller one.
  # A list that reaches its cap says so (`capped?`) rather than pass for a total.
  @caps %{terms: 100, people: 50}
  @people_scope_caps %{terms: 500, people: 250}
  @tag_limit 20
  @tag_scope_limit 50
  @post_limit 10
  @post_scope_limit 25
  @preview 3
  @tag_preview 10

  # TLD bound is {2,} (not {2,4}): modern TLDs run long (.online, .software),
  # and an unrecognized email would wrongly fall through to phonetic name search.
  @email_regex ~r/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/

  # Operator keys (German first, then the English, French and Italian aliases) →
  # parsed field. Every interface language gets its own spelling, because the
  # search help page shows the examples in the reader's language and an example
  # that does not parse is worse than none. The query is downcased before it is
  # split, so every key here is lowercase.
  #
  # **`nome` and `nom` are two different fields, and that is not a typo.**
  # Italian `nome` is the given name; French `nom` is the family name, whose
  # given-name counterpart is `prénom`. They are exact keys, so the lookup can
  # never confuse them — but anybody editing this list can, which is why they
  # are worth a sentence. An accented key gets its unaccented twin beside it
  # (`prenom`, `competence`, the way `citta` already sits beside `città`),
  # because a French keyboard is not what every reader of a French page has.
  @field_ops %{
    "tag" => :tag,
    "skill" => :tag,
    "competence" => :tag,
    "compétence" => :tag,
    "vorname" => :first_name,
    "first" => :first_name,
    "nome" => :first_name,
    "prenom" => :first_name,
    "prénom" => :first_name,
    "nachname" => :last_name,
    "last" => :last_name,
    "cognome" => :last_name,
    "nom" => :last_name,
    "ort" => :city,
    "stadt" => :city,
    "city" => :city,
    "citta" => :city,
    "città" => :city,
    "ville" => :city,
    "status" => :status,
    "stato" => :status,
    "statut" => :status
  }

  # The job-availability values the `status:` operator accepts (issue #935);
  # the shared source is `Vutuv.Accounts.User.employment_statuses/0`.
  @status_values ~w(open looking)

  @scopes [:all, :people, :organizations, :tags, :posts]

  @doc "Free-text queries shorter than this many characters return no results."
  def min_chars, do: @min_chars

  @doc """
  How many results one page of the people, tags or posts scope shows.
  Organizations page at the directory's own size (`Organizations.directory_page/1`).
  """
  def per_page(:people), do: 25
  def per_page(:tags), do: @tag_scope_limit
  def per_page(:posts), do: @post_scope_limit

  @doc "Whether the query looks like an email address (searched exactly)."
  def email?(value) when is_binary(value), do: Regex.match?(@email_regex, value)
  def email?(_value), do: false

  @doc """
  Parses a raw query into what to search where. Operators: `vorname:x` /
  `first:x` and `nachname:x` / `last:x` search a single name field, `@x` the
  username, `tag:x` / `skill:x` (has that tag) filters **both people and
  posts** (issue #946), and the people-only filter `ort:x` / `stadt:x` /
  `city:x` (has an address in that city) - both combinable with a name
  ("müller tag:php"). `status:open` / `status:looking` (issue #935) filters by
  job-availability, honored only for a signed-in viewer.
  A query wrapped in double quotes sets `exact?` (equality instead of substring
  + phonetics). Options: `:scope` (`:all | :people | :organizations | :tags |
  :posts`, the UI filter; operators override it, reported back as
  `scope_pinned?`) and `:exact` (the UI toggle, OR-ed with the quotes).
  """
  def parse(value, opts \\ []) when is_binary(value) do
    # Cut first, so nothing this function reaches walks more than the cap.
    raw = value |> SearchText.cap() |> String.trim() |> String.downcase()
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

    # Only `open`/`looking` are real status filters; anything else is a plain
    # word (so "status:foo" degrades to free text rather than matching nothing).
    status = if fields[:status] in @status_values, do: fields[:status]

    # The people-only operators pin the scope: the UI chips cannot override
    # them, so `scope_pinned?` lets the search page render them as disabled
    # (#846). `tag:` is deliberately NOT here: since issue #946 it finds both
    # people and posts, so it leaves the scope free for the chips to narrow.
    scope_pinned? =
      Enum.any?([:first_name, :last_name, :slug, :city], &fields[&1]) or status != nil

    scope = if scope_pinned?, do: :people, else: valid_scope(opts[:scope])

    %{
      raw: raw,
      text: words |> Enum.reverse() |> Enum.join(" "),
      tag: fields[:tag],
      first_name: fields[:first_name],
      last_name: fields[:last_name],
      slug: fields[:slug],
      city: fields[:city],
      status: status,
      exact?: quoted? or opts[:exact] == true,
      scope: scope,
      scope_pinned?: scope_pinned?
    }
  end

  @doc """
  Whether a parsed people query can power a saved-search alert (issue #935):
  it names at least one structured operator (tag: / ort: / status:) — a bare
  free-text or name search never triggers a people alert. The /search save
  button and the nightly sweeper share this one predicate.
  """
  def alertable?(%{tag: tag, city: city, status: status}), do: !!(tag || city || status)

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
         field when field != nil <- @field_ops[key],
         true <- valid_field_value?(field, field_value) do
      {:field, field, field_value}
    else
      _ -> :word
    end
  end

  # The status: operator only accepts the real availability values; anything
  # else (status:senior) stays a plain word so it degrades to free text rather
  # than silently matching nothing. Every other operator accepts any value.
  defp valid_field_value?(:status, value), do: value in @status_values
  defp valid_field_value?(_field, _value), do: true

  # An operator value is deliberate, so it may be shorter than free text. A
  # `status:` filter is runnable on its own (only for a signed-in viewer, gated
  # in `people/1`); the raw value is always a valid short word.
  defp runnable?(parsed) do
    String.length(parsed.text) >= @min_chars or
      (is_binary(parsed.status) and parsed.logged_in?) or
      Enum.any?(
        [parsed.tag, parsed.first_name, parsed.last_name, parsed.slug, parsed.city],
        &(is_binary(&1) and String.length(&1) >= @min_field_chars)
      )
  end

  @doc """
  The search-as-you-type matcher behind the Mastodon API's search. Returns
  `nil` for queries below the minimum length; otherwise a map with the
  normalized `:query`, the `:parsed` operator breakdown, the people split into
  `:exact_people` (literal substring matches) and `:similar_people` (matched
  only via Cologne/Soundex phonetics), matching `:tags` with
  `:tag_member_counts`, and public `:posts`. Accepts the same options as
  `parse/2`, plus `:viewer` (the signed-in `%User{}` or nil) which gates the
  `status:` operator — logged-out search ignores it (issue #935).

  The search page asks `page/2`, which adds organizations, CV matches, totals
  and pages on the same matching.
  """
  def instant(value, opts \\ [])

  def instant(value, opts) when is_binary(value) do
    parsed = parse_for(value, opts, @caps)

    if runnable?(parsed) do
      {exact, similar, _capped?} = people(parsed)
      viewer = opts[:viewer]

      tags =
        case tag_query(parsed) do
          nil -> []
          query -> fetch_tags(query, scope_limit(parsed, :tags, @tag_scope_limit, @tag_limit), 0)
        end

      posts =
        if post_search?(parsed) do
          limit = scope_limit(parsed, :posts, @post_scope_limit, @post_limit)
          Vutuv.Posts.search_public(parsed.text, post_opts(parsed, limit, 0))
        else
          []
        end

      %{
        query: parsed.raw,
        parsed: parsed,
        exact_people: status_visible(exact, parsed, viewer),
        similar_people: status_visible(similar, parsed, viewer),
        tags: tags,
        tag_member_counts: tag_member_counts(tags),
        posts: posts
      }
    end
  end

  def instant(_value, _opts), do: nil

  @doc """
  The search page's answer: every kind the scope covers, each as the rows the
  page shows and the total behind them. Under `:all` that is a preview of each
  kind (`preview/0` rows, ten tag chips), whose total is counted only when the
  preview came back full; under a kind's own scope it is one page of that kind
  (`:page`, `:per_page`), held inside the last page. `nil` below the minimum
  length, otherwise `:query`, `:parsed` and one map per kind, each carrying its
  `:total`, `:page` and `:per_page`:

    * `:people` — `:names` (the name matches, `instant/2`'s matcher), `:cv`
      (members whose CV names a matching employer or school, never one of the
      name matches; `matched_entries/3` says which entry), `:similar`,
      `:main_total` (names and CV matches) and `:capped?` (the name matches
      ran into their row cap, so the totals are a lower bound). The people
      scope pages over names then CV matches: the names arrive whole and are
      cut here, the CV matches as exactly the slice the page needs, counted
      in SQL, because an employer such as "GmbH" names hundreds.
    * `:organizations` — `:entries` and `:people_counts`, the public pages as
      the directory at /organizations finds them.
    * `:tags` — `:entries` and `:member_counts`.
    * `:posts` — `:entries`.
  """
  def page(value, opts \\ [])

  def page(value, opts) when is_binary(value) do
    parsed = parse_for(value, opts, @caps)
    parsed = if parsed.scope == :people, do: %{parsed | caps: @people_scope_caps}, else: parsed

    if runnable?(parsed) do
      requested = Keyword.get(opts, :page, 1)
      size = opts[:per_page]

      %{
        query: parsed.raw,
        parsed: parsed,
        people: people_page(parsed, requested, size || per_page(:people), opts[:viewer]),
        organizations: organization_page(parsed, requested, size),
        tags: tag_page(parsed, requested, size || per_page(:tags)),
        posts: post_page(parsed, requested, size || per_page(:posts))
      }
    end
  end

  def page(_value, _opts), do: nil

  @doc "How many results \"All\" shows of each kind before its link into the full list."
  def preview, do: @preview

  defp parse_for(value, opts, caps) do
    value |> parse(opts) |> Map.merge(%{logged_in?: opts[:viewer] != nil, caps: caps})
  end

  defp scope_limit(%{scope: kind}, kind, scope_limit, _all_limit), do: scope_limit
  defp scope_limit(_parsed, _kind, _scope_limit, all_limit), do: all_limit

  # One page of a kind that has a count and a fetch of its own: under its own
  # scope the counted page, held inside the last one; under "All" the preview,
  # counted only when it came back full — while typing, most previews do not.
  defp kind_page(nil, _selected?, _requested, size, _preview),
    do: %{entries: [], total: 0, page: 1, per_page: size}

  defp kind_page({count, fetch}, true, requested, size, _preview) do
    total = count.()
    page = clamp_page(requested, total, size)
    %{entries: fetch.(size, (page - 1) * size), total: total, page: page, per_page: size}
  end

  defp kind_page({count, fetch}, false, _requested, size, preview) do
    entries = fetch.(preview, 0)
    %{entries: entries, total: total_of(entries, preview, count), page: 1, per_page: size}
  end

  defp total_of(entries, limit, _count) when length(entries) < limit, do: length(entries)
  defp total_of(_entries, _limit, count), do: count.()

  # A requested page past the last one shows the last one, so an old link or a
  # narrowed query never lands on an empty page with a pager beneath it.
  defp clamp_page(page, total, size),
    do: page |> max(1) |> min(Vutuv.Pages.total_pages(total, size))

  @doc """
  The people-side matcher for saved-search alerts (issue #935): confirmed,
  non-moderated members that match the structured operators in `q`
  (`tag:`/`ort:`/`status:`) and are **new** to the search — either registered or
  changed their availability status in `(since, until]`. `viewer` is the alert
  recipient (always a signed-in member); `opts` take `:since`, `:until`,
  `:limit` (default 5) and `:blocked_ids` (a MapSet subtracted both ways).

  A search with no structured people filter yields `[]` (a bare free-text alert
  would fire on every new registration). When the search carries a `status:`
  filter the results are additionally passed through
  `Accounts.job_search_visibility/2`, so a member who put the recipient on their
  job-search exclusion list (#938) — or blocked them — never rides along in the
  mail. Free-text / name phonetics are deliberately not part of alert matching.
  """
  def new_matching_people(q, %User{} = viewer, opts) when is_binary(q) do
    parsed =
      q
      |> parse(exact: opts[:exact] == true)
      |> Map.put(:logged_in?, true)

    since = Keyword.fetch!(opts, :since)
    until = Keyword.fetch!(opts, :until)
    limit = Keyword.get(opts, :limit, 5)
    blocked = Keyword.get(opts, :blocked_ids, MapSet.new())

    if alertable?(parsed) do
      parsed
      |> filtered_users()
      |> exclude_blocked(blocked)
      |> where(
        [user: u],
        (u.inserted_at > ^since and u.inserted_at <= ^until) or
          (u.employment_status_set_at > ^since and u.employment_status_set_at <= ^until)
      )
      |> order_by([user: u],
        desc:
          fragment(
            "GREATEST(?, COALESCE(?, ?))",
            u.inserted_at,
            u.employment_status_set_at,
            u.inserted_at
          )
      )
      |> limit(50)
      |> Repo.all()
      |> honor_status_exclusion(parsed, viewer)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp exclude_blocked(query, blocked) do
    case MapSet.to_list(blocked) do
      [] -> query
      ids -> where(query, [user: u], u.id not in ^ids)
    end
  end

  # For a status: search the base SQL already dropped "hidden" statuses; this
  # applies the per-viewer job-search exclusion (#938, and any block) so the
  # alert mail never surfaces a member who hid their availability from the
  # recipient. Non-status searches carry no such per-viewer gate. Lazy on
  # purpose: each check costs 1-2 EXISTS queries, and the caller's
  # `Enum.take(limit)` needs only the first few survivors of the 50-candidate
  # page, not all 50 checked eagerly.
  defp honor_status_exclusion(people, %{status: status}, viewer) when status in @status_values do
    Stream.filter(people, &Accounts.job_search_visibility(&1, viewer).employment_status)
  end

  defp honor_status_exclusion(people, _parsed, _viewer), do: people

  # The live `/search` results get the same gate as the alert mail. It used to be
  # skipped here, called "a transient interactive query" — but the exclusion list
  # (#938) is a promise about one fact, and hiding that fact on the profile while
  # `status:looking` still lists the member is not keeping it.
  #
  # `viewer_excluded?/2` rather than the alert path's `job_search_visibility/2`:
  # the rows here come from `list_people/1`, which selects a narrow struct, so
  # every visibility column reads `nil` and that predicate would answer "hidden"
  # for everybody. It does not have to be asked anyway — `filter_status/2` has
  # already required a non-hidden status in SQL and the operator only runs for a
  # signed-in viewer, so the exclusion is the one question left, and it needs
  # nothing but the two ids.
  defp status_visible(people, %{status: status}, %User{} = viewer)
       when status in @status_values do
    excluded = people |> Enum.map(& &1.id) |> Accounts.excluded_owner_ids(viewer)
    Enum.reject(people, &MapSet.member?(excluded, &1.id))
  end

  defp status_visible(people, _parsed, _viewer), do: people

  # `{exact, similar, capped?}`: `capped?` says the query ran into its row cap,
  # so there are more people than came back and the page must not claim a total.
  defp people(%{scope: scope}) when scope not in [:all, :people], do: {[], [], false}

  defp people(parsed) do
    cond do
      is_binary(parsed.slug) ->
        parsed
        |> filtered_users()
        |> by_field(:username, parsed.slug, parsed.exact?)
        |> list_people(parsed)
        |> listed(parsed)

      is_binary(parsed.first_name) or is_binary(parsed.last_name) ->
        parsed |> people_by_name() |> listed(parsed)

      # Pure filter search: "tag:php" / "ort:koblenz" without a name lists
      # everyone matching the filter(s).
      parsed.text == "" ->
        parsed |> people_by_filter() |> listed(parsed)

      String.length(parsed.text) < @min_chars ->
        {[], [], false}

      email?(parsed.text) ->
        {search_by_email(parsed.text), [], false}

      parsed.exact? ->
        exact_people(parsed)

      true ->
        substring_and_phonetic_people(parsed)
    end
  end

  defp listed(people, parsed), do: {people, [], length(people) >= parsed.caps.people}

  defp people_by_name(parsed) do
    [first_name: parsed.first_name, last_name: parsed.last_name]
    |> Enum.filter(fn {_field, value} -> is_binary(value) end)
    |> Enum.reduce(filtered_users(parsed), fn {field, value}, query ->
      by_field(query, field, value, parsed.exact?)
    end)
    |> list_people(parsed)
  end

  defp people_by_filter(parsed) do
    if parsed.tag || parsed.city || status_filter(parsed) do
      parsed |> filtered_users() |> list_people(parsed)
    else
      []
    end
  end

  # The tag (tag:), city (ort:) and status: people filters, applied as EXISTS
  # subqueries (tag/city) or a scalar predicate (status) against whatever query
  # carries a named :user binding - the users table for field searches, the
  # search_terms join for name searches.
  defp filtered_users(parsed) do
    visible_users()
    |> apply_people_filters(parsed)
  end

  # Applies the tag: / ort: / status: people filters to any query that
  # carries a named :user binding (users table for field searches, the
  # search_terms join for name searches).
  defp apply_people_filters(query, parsed) do
    query
    |> filter_tag(parsed.tag, parsed.exact?)
    |> filter_city(parsed.city, parsed.exact?)
    |> filter_status(status_filter(parsed))
  end

  # The status: operator only applies to a signed-in viewer (issue #935);
  # logged-out search ignores it. Returns the status string or nil.
  defp status_filter(%{logged_in?: true, status: status}) when status in @status_values,
    do: status

  defp status_filter(_parsed), do: nil

  # A member matches `status:` when they carry that availability and it is
  # visible to a signed-in member (never "hidden" — issue #928). The per-viewer
  # exclusion list (#938) is applied after this, in `status_visible/3`, because
  # it is a per-pair question this SQL predicate cannot ask.
  defp filter_status(query, status) when status in @status_values do
    where(
      query,
      [user: u],
      u.employment_status == ^status and u.employment_status_visibility != "hidden"
    )
  end

  defp filter_status(query, _status), do: query

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
        infix = contains(tag)

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
        infix = contains(city)

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
    where(query, [user: u], ilike(field(u, ^field), ^contains(value)))
  end

  defp list_people(query, parsed) do
    query
    |> order_by([user: u], asc: u.last_name, asc: u.first_name)
    |> limit(^parsed.caps.people)
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
    rows =
      from(t in SearchTerm,
        join: u in assoc(t, :user),
        as: :user,
        where:
          account_confirmed_row(u) and t.score == 100 and
            t.value == ^parsed.text,
        limit: ^parsed.caps.terms,
        select: struct(u, ^people_fields())
      )
      |> exclude_moderated()
      |> apply_people_filters(parsed)
      |> Repo.all()

    {Enum.uniq_by(rows, & &1.id), [], length(rows) >= parsed.caps.terms}
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
        limit: ^parsed.caps.terms,
        select: %{score: t.score, value: t.value, user: struct(u, ^people_fields())}
      )
      |> phonetic_term_match(value)
      |> exclude_moderated()
      |> apply_people_filters(parsed)
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

    {exact, similar, length(terms) >= parsed.caps.terms}
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
    infix = contains(value)

    from([t, user: u] in query,
      where:
        account_confirmed_row(u) and
          (like(t.value, ^infix) or ^cologne == t.value or ^soundex == t.value)
    )
  end

  # --- people ---------------------------------------------------------------

  # The people the page shows, see `page/2`: the name matches cut to the page,
  # then exactly the CV matches that fill it.
  defp people_page(parsed, requested, size, viewer) do
    {exact, similar, capped?} = people(parsed)
    exact = status_visible(exact, parsed, viewer)
    cv_query = cv_query(parsed, exact)

    {page, names, cv, cv_total} =
      if parsed.scope == :people do
        cv_total = count(cv_query)
        page = clamp_page(requested, length(exact) + cv_total, size)
        names = exact |> Enum.drop((page - 1) * size) |> Enum.take(size)
        offset = max((page - 1) * size - length(exact), 0)
        {page, names, fetch_cv(cv_query, offset, size - length(names)), cv_total}
      else
        names = Enum.take(exact, @preview)
        preview = fetch_cv(cv_query, 0, @preview)
        cv_total = total_of(preview, @preview, fn -> count(cv_query) end)
        {1, names, Enum.take(preview, @preview - length(names)), cv_total}
      end

    # A CV hit is a real match and outranks a guess at how a name sounds.
    similar = similar |> status_visible(parsed, viewer) |> drop_cv_matches(cv_query)
    main_total = length(exact) + cv_total

    %{
      names: names,
      # The per-viewer `status:` exclusion runs after the slice, like it does
      # for the name matches, so a page can come out one short for that viewer.
      cv: status_visible(cv, parsed, viewer),
      similar: shown_similar(similar, parsed.scope, page, size),
      main_total: main_total,
      total: main_total + length(similar),
      capped?: capped?,
      page: page,
      per_page: size
    }
  end

  # The people scope keeps its similar names below the first page, where they
  # help most, and never more of them than a page holds.
  defp shown_similar(similar, :people, 1, size), do: Enum.take(similar, size)
  defp shown_similar(_similar, :people, _page, _size), do: []
  defp shown_similar(similar, _scope, _page, _size), do: Enum.take(similar, @preview)

  defp count(nil), do: 0
  defp count(query), do: Repo.aggregate(query, :count)

  # --- people found through their CV ---------------------------------------

  # Members whose CV names an employer or a school matching the free text, on
  # the same terms as the name search: the tag/city/status filters apply, and the
  # people-only field operators (`@handle`, `vorname:`) and an email mean the
  # searcher asked for something else. Everybody the name search already found
  # is left out, so nobody is listed twice. `nil` when there is nothing to ask.
  defp cv_query(%{scope: scope}, _found) when scope not in [:all, :people], do: nil

  defp cv_query(parsed, found) do
    if cv_searchable?(parsed) do
      found_ids = Enum.map(found, & &1.id)

      parsed
      |> filtered_users()
      |> where([user: u], u.id in subquery(cv_user_ids(parsed.text, parsed.exact?)))
      |> where([user: u], u.id not in ^found_ids)
    end
  end

  defp cv_searchable?(parsed) do
    is_nil(parsed.slug) and is_nil(parsed.first_name) and is_nil(parsed.last_name) and
      String.length(parsed.text) >= @min_chars and not email?(parsed.text)
  end

  defp fetch_cv(nil, _offset, _limit), do: []
  defp fetch_cv(_query, _offset, limit) when limit <= 0, do: []

  defp fetch_cv(query, offset, limit) do
    query
    |> order_by([user: u], asc: u.last_name, asc: u.first_name, asc: u.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([user: u], struct(u, ^people_fields()))
    |> Repo.all()
  end

  defp drop_cv_matches(similar, nil), do: similar
  defp drop_cv_matches([], _cv_query), do: []

  defp drop_cv_matches(similar, cv_query) do
    similar_ids = Enum.map(similar, & &1.id)

    matched =
      cv_query
      |> where([user: u], u.id in ^similar_ids)
      |> select([user: u], u.id)
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(similar, &MapSet.member?(matched, &1.id))
  end

  # The one rule for "this CV names the place", as three one-table queries: the
  # member's own employer text, the name of a linked **public** organization
  # page (the SQL side of `WorkExperience.linked_organization/1`, since a
  # pending or frozen page shows its name nowhere else either), and a school.
  # Both `cv_user_ids/2` and `matched_entries/3` read it, so the rows a search
  # finds and the line each one explains itself with cannot drift apart.
  defp cv_arms(pattern) do
    [
      from(w in WorkExperience,
        as: :entry,
        left_join: o in Organization,
        as: :page,
        on: o.id == w.organization_id and organization_public_row(o),
        where: ilike(w.organization, ^pattern)
      ),
      from(w in WorkExperience,
        as: :entry,
        join: o in Organization,
        as: :page,
        on: o.id == w.organization_id and organization_public_row(o),
        where: ilike(o.name, ^pattern)
      ),
      from(e in Education, as: :entry, where: ilike(e.school, ^pattern))
    ]
  end

  defp cv_pattern(text, true), do: equals(text)
  defp cv_pattern(text, false), do: contains(text)

  # Everybody with a work experience (any, ended or running) or an education
  # entry naming the place. A **union of one-table queries**, never an OR across
  # tables: Postgres builds a bitmap only over arms of one relation, so an OR
  # that reads a second table gives up every index in it and scans. Oliver
  # Andrich measured this shape for the member directory (PR #2217) on a copy
  # with 100k members: 54.8 ms as one OR, 0.645 ms as this union, every arm a
  # bitmap scan on its own trigram index.
  defp cv_user_ids(text, exact?) do
    text
    |> cv_pattern(exact?)
    |> cv_arms()
    |> Enum.map(&select(&1, [entry: x], x.user_id))
    |> Enum.reduce(fn arm, acc -> union(acc, ^arm) end)
  end

  @doc """
  The CV entry each of `users` was found by, as `%{user_id => entry}`: a
  `%WorkExperience{}` (with its public `organization_page` loaded, so the view
  names the employer the way every other surface does) or an `%Education{}`.

  A result row normally shows a member's current job, which explains nothing
  when the search found them through a role they left in 2016 or a university
  they attended. So the page asks, for the rows it renders, which entry
  answered. Work before school, a running role before an ended one, then the
  most recent. One query per arm over the rendered ids, never one per row.
  """
  # What the result line prints and `Organizations.public_visible?/1` reads, and
  # no more: `description` is a text column LinkedIn imports fill to 10k.
  @job_line_fields ~w(id user_id title organization organization_id start_month start_year end_month end_year)a
  @page_line_fields ~w(id name slug status frozen_at)a
  @education_line_fields ~w(id user_id school degree start_month start_year end_month end_year)a

  def matched_entries([], _text, _exact?), do: %{}

  def matched_entries(users, text, exact?) do
    ids = Enum.map(users, & &1.id)
    [by_text, by_page, by_school] = text |> cv_pattern(exact?) |> cv_arms()

    jobs =
      for arm <- [by_text, by_page],
          {job, page} <-
            Repo.all(
              from([entry: w, page: o] in arm,
                where: w.user_id in ^ids,
                select: {struct(w, ^@job_line_fields), struct(o, ^@page_line_fields)}
              )
            ),
          do: {0, %{job | organization_page: page}}

    schools =
      from([entry: e] in by_school,
        where: e.user_id in ^ids,
        select: struct(e, ^@education_line_fields)
      )
      |> Repo.all()
      |> Enum.map(&{1, &1})

    (jobs ++ schools)
    |> Enum.group_by(fn {_rank, entry} -> entry.user_id end)
    |> Map.new(fn {user_id, entries} ->
      {_rank, entry} = Enum.min_by(entries, &entry_rank/1)
      {user_id, entry}
    end)
  end

  defp entry_rank({kind, entry}) do
    {kind, if(is_nil(entry.end_year), do: 0, else: 1), -(entry.end_year || 0),
     -(entry.start_year || 0), entry.id}
  end

  # --- organizations --------------------------------------------------------

  # The public organization pages whose name, city or other name matches: the
  # same set and the same match as the directory at /organizations, so a page
  # found here is one a visitor can open, at the directory's page size.
  defp organization_page(%{scope: scope, text: text}, requested, size)
       when scope in [:all, :organizations] do
    if String.length(text) >= @min_chars do
      {page, per_page} = if scope == :organizations, do: {requested, size}, else: {1, @preview}
      result = Organizations.directory_page(search: text, page: page, per_page: per_page)

      result
      |> Map.take([:entries, :total, :page, :per_page])
      |> Map.put(
        :people_counts,
        result.entries |> Enum.map(& &1.id) |> Organizations.people_counts()
      )
    else
      no_organizations()
    end
  end

  defp organization_page(_parsed, _requested, _size), do: no_organizations()

  defp no_organizations, do: %{entries: [], total: 0, page: 1, per_page: nil, people_counts: %{}}

  # --- tags -----------------------------------------------------------------

  defp tag_query(%{scope: scope}) when scope not in [:all, :tags], do: nil
  defp tag_query(%{text: ""}), do: nil
  defp tag_query(parsed), do: visible_tags(parsed.text, parsed.exact?)

  defp fetch_tags(query, limit, offset) do
    query |> order_by([t], asc: t.name) |> limit(^limit) |> offset(^offset) |> Repo.all()
  end

  defp tag_page(parsed, requested, size) do
    kinds =
      case tag_query(parsed) do
        nil -> nil
        query -> {fn -> count(query) end, &fetch_tags(query, &1, &2)}
      end

    page = kind_page(kinds, parsed.scope == :tags, requested, size, @tag_preview)
    Map.put(page, :member_counts, tag_member_counts(page.entries))
  end

  # Tags match on their alternative names too (issue #1338) — searching "ROR"
  # has to find the Ruby on Rails page — but the row that comes back is always
  # the topic, never the alias, so one subject appears once. `alias_matches/1`
  # is the id set of canonicals whose aliases match; the outer query keeps only
  # unmerged rows.
  defp visible_tags(needle, true) do
    aliases =
      from(a in Tag,
        where: not is_nil(a.merged_into_id),
        where: fragment("lower(?)", a.name) == ^needle or a.slug == ^needle,
        select: a.merged_into_id
      )

    from(t in Tag.not_merged(),
      where:
        fragment("lower(?)", t.name) == ^needle or t.slug == ^needle or
          t.id in subquery(aliases)
    )
  end

  defp visible_tags(needle, false) do
    infix = contains(needle)

    aliases =
      from(a in Tag,
        where: not is_nil(a.merged_into_id),
        where: ilike(a.name, ^infix) or ilike(a.slug, ^infix),
        select: a.merged_into_id
      )

    from(t in Tag.not_merged(),
      where: ilike(t.name, ^infix) or ilike(t.slug, ^infix) or t.id in subquery(aliases)
    )
  end

  # How many members carry each found tag - the number that makes a tag chip
  # worth clicking.
  # The tag chips' "N members", counted the way the tag page lists: `Vutuv.Tags`
  # owns that gate, so the chip and the page it leads to cannot drift apart.
  defp tag_member_counts(tags), do: Tags.listed_member_counts(tags)

  # Posts are matched by Postgres full-text search over the body, which is
  # word-exact already; the `tag:` operator (issue #946) additionally filters
  # by tag, so a bare `tag:php` lists posts carrying that tag even with no body
  # words. The exact toggle applies only to the tag match (the body query is
  # always full-text). Nothing to search — no words and no tag — yields nothing.
  defp post_search?(%{scope: scope}) when scope not in [:all, :posts], do: false
  defp post_search?(%{text: "", tag: nil}), do: false
  defp post_search?(_parsed), do: true

  defp post_opts(parsed, limit, offset),
    do: [tag: parsed.tag, exact: parsed.exact?, limit: limit, offset: offset]

  defp post_page(parsed, requested, size) do
    kinds =
      if post_search?(parsed) do
        {fn -> Vutuv.Posts.count_public_search(parsed.text, post_opts(parsed, nil, 0)) end,
         &Vutuv.Posts.search_public(parsed.text, post_opts(parsed, &1, &2))}
      end

    kind_page(kinds, parsed.scope == :posts, requested, size, @preview)
  end

  @doc """
  The member with exactly that email address, or `[]`.

  Only addresses the owner flagged public are findable (`public?` defaults to
  false): a private address must not even confirm that an account exists.
  """
  def search_by_email(value) do
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
  # owned by Vutuv.Moderation.Query.
  defp exclude_moderated(query) do
    from([user: u] in query, where: not account_hidden_row(u))
  end

  defp phoneticize_search_value(value, algorithm) do
    # Split on non-letter runs (Unicode-aware, so umlauts/ß stay INSIDE the word).
    # Each letter run is then encoded whole — the way the stored terms encode each
    # name part — so "müller" → "657" matches, instead of the old [^a-z] split
    # that treated ü as a separator and left it literal ("6ü57").
    for(section <- Regex.split(~r/[^\p{L}]+/u, value, include_captures: true)) do
      phoneticize_section(section, algorithm)
    end
    # Recombine the search value with phoneticized words
    |> Enum.join()
  end

  defp phoneticize_section(section, algorithm) do
    if Regex.match?(~r/^\p{L}+$/u, section) do
      # Phoneticize the words based on the algorithm parameter (the encoders
      # NFD-normalize umlauts internally, exactly like the stored terms).
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
