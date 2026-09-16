defmodule Vutuv.Directory do
  @moduledoc """
  The public member directory (`/system/members`): **every** member the site
  lists publicly — activated, not moderation-hidden — grouped alphabetically
  for browsing.

  Two sets live here, and the difference is the whole point. `listed_users/0`
  is what the directory shows: the same gate the most-followed listing, the
  follower lists and the search page have always used, so the directory no
  longer hides members those pages have listed all along.
  `indexable_users/0` is the narrower **crawlable** set (`noindex?: false`)
  that `Vutuv.Sitemap` advertises and that decides whether a directory row
  links its profile `rel="nofollow"` — an opted-out member is listed for
  people, and crawlers are told not to walk through to the profile.

  Members are filed by **last name** (first name only as a fallback), with
  accents folded into their base letter so Özil sorts under O (DIN 5007);
  names that start with no letter at all share the `"other"` bucket. The
  bucket expression lives in SQL so the letter pages paginate in the
  database (`Vutuv.Pages`), like every other browse page.

  `search/3` is the other half of the page: the alphabet answers "who is filed
  under M", a search box answers "where is Müller", which is what somebody
  arriving with a name in mind actually types. It searches three columns on
  `users` plus two CV fields — the employers on a member's work experiences
  and the schools on their education entries, **all** of them, so a company
  somebody left long ago is as findable as the one they are at now.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [cap: 1, contains: 1, normalize_search: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.SearchText

  @letters Enum.map(?a..?z, &<<&1>>)

  # The URL segment of the non-letter bucket; SQL spells it "#".
  @other "other"

  # Deliberately denser than the site-wide 250 (`Vutuv.Pages.max_page_items/0`):
  # a directory page is browsed, not scanned once, so short pages with a
  # visible pager beat one endless scroll.
  @per_page 50

  # What the search box looks in, in checkbox order. Also the allowlist the
  # `fields` param is read through — never `String.to_atom/1` on a URL value.
  #
  # The first three are columns on `users`; `:organization` and `:school` are
  # the two CV fields, each a query over a member's own entries rather than a
  # column here. Their order is the reading order of a profile: who somebody is,
  # then where they worked, then where they studied.
  # `:user` is a column on `users`, `:cv` a query over the member's own entries.
  # Declared once: two hand-kept lists are the one thing a sixth field would
  # silently forget, and the kind decides three things (the match query, whether
  # a row's line may be taken over, and the order entries rank in).
  @fields [first_name: :user, last_name: :user, username: :user, organization: :cv, school: :cv]
  @search_fields Keyword.keys(@fields)
  @cv_fields for({field, :cv} <- @fields, do: field)

  # Three, like `Vutuv.Search.min_chars/0`, and for a reason that is not
  # symmetry: pg_trgm needs three characters to form a trigram, so a shorter
  # needle plans a sequential scan of `users` whatever indexes exist (measured
  # 27.1 ms against 1.3 ms on a 100k-row copy). Two would make the very first
  # query past the minimum the most expensive one on the page and the one most
  # likely to match half the membership.
  @min_query_chars 3

  # A search reveals its results in bites rather than as one wall, and stops
  # growing well before a page becomes unreadable: past the ceiling the answer
  # is another letter in the box, not another press.
  @results_step 25

  # The rows a listing row actually renders, plus the headline
  # `work_information_map/2` falls back to — `users` carries ~98 columns and a
  # search fetches up to `results_ceiling/0` rows per keystroke, so selecting
  # the whole struct would move ~1.5 KB per row where ~150 bytes will do. The
  # same projection `Vutuv.Search` and the most-followed listing use for the
  # same `card_list` template; `noindex?` rides in it, which is what lets
  # `UserHelpers.profile_rel/1` decide the row's `rel` without a second query.
  @listing_fields [:headline | User.listing_fields()]

  # ascii() is deliberate: BETWEEN 'a' AND 'z' would be collation-dependent
  # (an ICU locale sorts 'ä' inside that range), while the code-point check
  # is exact. The translate/3 alphabet folds the accented letters that
  # actually start European names; anything it doesn't cover lands in "#".
  # Both cases are listed because lower() under the C locale leaves
  # non-ASCII letters alone ('Ö' stays 'Ö'); building from/to from pairs
  # keeps the two translate alphabets the same length (a shorter "to" would
  # make translate silently *delete* the unmatched characters).
  @folds [
    {"äÄ", "a"},
    {"öÖ", "o"},
    {"üÜ", "u"},
    {"àáâãåæÀÁÂÃÅÆ", "a"},
    {"çÇ", "c"},
    {"èéêëÈÉÊË", "e"},
    {"ìíîïÌÍÎÏ", "i"},
    {"ñÑ", "n"},
    {"òóôõøÒÓÔÕØ", "o"},
    {"ùúûÙÚÛ", "u"},
    {"ýÿÝ", "y"},
    {"šŠ", "s"},
    {"žŽ", "z"}
  ]
  @fold_from Enum.map_join(@folds, fn {chars, _to} -> chars end)
  @fold_to Enum.map_join(@folds, fn {chars, to} -> String.duplicate(to, String.length(chars)) end)

  defmacrop letter_bucket(u) do
    expr = """
    CASE WHEN ascii(translate(lower(substr(coalesce(nullif(trim(?),''), ?, ''),1,1)),
                    '#{@fold_from}', '#{@fold_to}')) BETWEEN 97 AND 122
         THEN translate(lower(substr(coalesce(nullif(trim(?),''), ?, ''),1,1)),
                    '#{@fold_from}', '#{@fold_to}')
         ELSE '#' END
    """

    quote do
      fragment(
        unquote(expr),
        unquote(u).last_name,
        unquote(u).first_name,
        unquote(u).last_name,
        unquote(u).first_name
      )
    end
  end

  # "Zabel, Anna" before "Zabel, Zoe": last name (or the fallback first
  # name) decides the shelf, the first name breaks ties within it.
  defmacrop name_sort_key(u) do
    quote do
      fragment(
        "lower(coalesce(nullif(trim(?),''), ?, ''))",
        unquote(u).last_name,
        unquote(u).first_name
      )
    end
  end

  @doc "The a-z letters of the directory (without the `other` bucket)."
  def letters, do: @letters

  @doc "The bucket for names that start with no letter (its URL segment)."
  def other, do: @other

  @doc "True for a letter segment the directory serves: a-z or `other`."
  def valid_letter?(letter), do: letter in @letters or letter == @other

  @doc "The directory's page size (the `per_page` behind `members_page/2` and the pager)."
  def per_page, do: @per_page

  @doc """
  The listed member set: activated and not moderation-hidden — what the
  directory shows. `account_confirmed_row/1` is the shared confirmed-member
  gate every other listing query uses: it treats a legacy NULL flag as
  confirmed, so the directory lists the same members as the most-followed
  listing, the follower lists and search rather than hand-rolling a stricter
  `u.email_confirmed?` test here.
  """
  def listed_users do
    from(u in User, where: account_confirmed_row(u) and not account_hidden_row(u))
  end

  @doc """
  The crawlable subset of `listed_users/0`: members who did not opt out of
  search engines (`noindex?: false`). What `Vutuv.Sitemap` advertises, and
  the line the directory's `rel="nofollow"` is drawn along — an opted-out
  member is listed for people to browse, and crawlers are asked not to walk
  through the row to the profile.
  """
  def indexable_users do
    where(listed_users(), [u], not u.noindex?)
  end

  @doc "The fields the search box can look in, in checkbox order."
  def search_fields, do: @search_fields

  @doc "Shortest query the search box answers; below it, it says so instead."
  def min_query_chars, do: @min_query_chars

  @doc "How many more results one press of the search box's \"show more\" reveals."
  def results_step, do: @results_step

  @doc """
  The most results one search will ever render before asking for a narrower
  query — the site-wide page maximum, read from `Vutuv.Pages` rather than
  copied, so an installation that lowers that knob lowers this too.
  """
  def results_ceiling, do: Pages.max_page_items()

  @doc """
  How many rows a search may render, from whatever the request asked for: an
  integer or the `show` param's string, clamped to `results_ceiling/0`, with
  anything else (absent, blank, zero, negative, not a number) falling back to
  one bite.

  One owner rather than a clamp in the query and a second one where the param
  is read: the ceiling is what stops `?show=100000` from asking Postgres for
  the whole membership, and a ceiling enforced in two places is a ceiling that
  will eventually be enforced in one.
  """
  def results_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _rest} -> results_limit(n)
      :error -> @results_step
    end
  end

  def results_limit(value) when is_integer(value) and value > 0,
    do: min(value, results_ceiling())

  def results_limit(_value), do: @results_step

  @doc """
  The search fields a request asks for, read through the allowlist: the `fields`
  param the checkboxes send, falling back to **all** of them.

  That fallback is the whole "at least one box stays ticked" rule, and it holds
  on every path because it is asked on every path. An unticked checkbox sends
  nothing at all, so a form submitted with all three off arrives here
  indistinguishable from one that named no preference — and answering either
  with "look in no field" would be a search box that finds nobody however the
  name is spelled.
  """
  def parse_search_fields(fields) do
    # Strings from a form, atoms from a caller that already parsed once. Both
    # are compared as strings so a caller never has to convert on the way in
    # and back out again — `to_string/1` on an atom cannot fail, and anything
    # that is neither is dropped by the allowlist below anyway.
    wanted =
      fields
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
      |> MapSet.new(&to_string/1)

    case Enum.filter(@search_fields, &MapSet.member?(wanted, Atom.to_string(&1))) do
      [] -> @search_fields
      selected -> selected
    end
  end

  @doc """
  Members whose selected fields contain `query`: a case-insensitive substring
  in each field, OR-ed across the fields, so "mei" finds Meier and Meierhoff
  and a search across all of them finds somebody by whichever of their names
  the searcher happens to remember. With both name fields selected the **whole
  name** matches too ("anna mei"), because that is what a person with a name in
  mind types and matching it per column would find nothing.

  The two CV fields are not columns here: each asks whether the member has any
  work experience (or education entry) naming that place, with no date filter,
  so a company somebody left in 2016 answers exactly like the one they are at
  now. Set membership rather than a join, or a member with three stations at
  the same employer would be listed three times and counted three times.

  Returns `nil` below `min_query_chars/0` (the box says so rather than answering
  with the whole membership), otherwise `%{users: users, total: total}` where
  `total` counts **every** match while `users` holds at most `limit` of them,
  filed by last name like every other page here. `limit` goes through
  `results_limit/1`, so a short query against a large installation can neither
  render a hundred thousand rows nor be talked into it by a crafted URL.

  The total rides along on the rows as a window count rather than as a second
  `Repo.aggregate/2`: both have to walk the whole match set, and one walk is
  half the work of two on a query a member re-runs at every keystroke (measured
  33 ms against 67 ms on a 100k-row copy).
  """
  def search(query, fields \\ @search_fields, limit \\ @results_step) do
    # `/system/members?q=` is open to visitors and `field_match/2` emits one
    # leading-wildcard `ILIKE` per word per selected column, so the query is cut
    # to `SearchText.max_chars/0` before any of that is built.
    with needle when is_binary(needle) <- query |> cap() |> normalize_search(),
         true <- String.length(needle) >= @min_query_chars do
      listed_users()
      |> where(^field_match(parse_search_fields(fields), needle))
      |> filed_order()
      |> limit(^results_limit(limit))
      |> select([u], {struct(u, ^@listing_fields), fragment("count(*) OVER ()")})
      |> Repo.all()
      |> page_with_total()
    else
      _ -> nil
    end
  end

  # A window count is per row, so an empty result set carries no count at all.
  defp page_with_total([]), do: %{users: [], total: 0}

  defp page_with_total([{_user, total} | _rest] = rows),
    do: %{
      users: rows |> Enum.map(&elem(&1, 0)) |> Images.preload_member_images(),
      total: total
    }

  # "Zabel, Anna" before "Zabel, Zoe", with the id (creation order, UUID v7) as
  # the tiebreaker. One definition for the letter pages and the search, so a
  # result can never be filed differently from the page it would be browsed on.
  defp filed_order(query),
    do: order_by(query, [u], asc: name_sort_key(u), asc: u.first_name, asc: u.id)

  # Every word of the query has to match **some** selected field: "anna mei"
  # finds Anna Meier because "anna" matches a first name and "mei" a last one.
  # A one-word query is a single set membership.
  #
  # Each word's set is a **UNION of one-table queries**, not an OR of
  # predicates, and that shape is the whole performance story here. Postgres
  # builds a `BitmapOr` only over arms of the *same* relation, so the moment one
  # arm of an OR reads another table — a CV entry, a linked organization page —
  # the planner gives up on every index in that OR and sequentially scans
  # `users`. Measured on a synthetic 100k-user / 300k-CV-row copy, searching all
  # five fields: 54.8 ms as one OR, **0.645 ms** as this union, where all six
  # arms come back as bitmap index scans on their own trigram index. The
  # name-only search this replaces measured 0.29 ms, so the CV fields cost
  # fractions of a millisecond rather than turning every keystroke into a scan.
  #
  # What keeps a member with three stations at the same employer **one** row and
  # one count is the set membership, not the `UNION`: `IN (…)` asks whether the
  # id is in the set, so `UNION ALL` answers identically (measured: both around
  # 0.7 ms, and swapping them turns no test red). The shape that would double
  # the member is a join, which the duplicate test in `directory_test.exs`
  # calibrates against. `UNION` stays because deduping inside the set is free
  # here and hands the outer membership test fewer rows.
  #
  # One cost this widens rather than creates, measured on the same copy: a word
  # **shorter** than `min_query_chars/0` forms no trigram, so every arm carrying
  # it is a sequential scan whatever indexes exist — and there are now three
  # more tables to scan. "siemens ag" (the "ag" is two characters) measured
  # 6.07 ms across the name fields alone and 52.2 ms across all five, where
  # "siemens healthineers" measured 1.98 ms and 2.73 ms. The minimum is checked
  # on the whole needle, not per word, and tightening that would change what a
  # search means rather than how it runs, so it is left as it is and written
  # down here.
  #
  # The obvious alternative for the names — matching the query against
  # `first || ' ' || last`, which is what `SearchText.name_ilike/3` adds and what
  # the admin browser and the composer's typeahead use — was measured and
  # rejected here for the same reason: a concatenation is an expression, and no
  # trigram index covers it. Splitting into words keeps every arm a bare column
  # `ILIKE`, and it matches "meier anna" too, which the concatenation never
  # could.
  defp field_match(fields, needle) do
    needle
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(dynamic(true), fn word, acc ->
      dynamic([u], ^acc and u.id in subquery(word_match(fields, contains(word))))
    end)
  end

  # The ids of everybody some selected field matches `pattern` on. `fields`
  # arrives through `parse_search_fields/1` and is therefore never empty, which
  # is what lets this reduce without a seed — "no field" could otherwise reach
  # the query as a set that matches nobody.
  defp word_match(fields, pattern) do
    fields
    |> Enum.flat_map(&field_queries(&1, pattern))
    |> Enum.reduce(fn query, acc -> union(acc, ^query) end)
  end

  # A member's work experiences, *all* of them: the field answers "has this
  # member ever worked there", so an ended role counts exactly like a running
  # one — which is the whole reason somebody ticks the box.
  #
  # Two queries, because the employer can be named in two places. The second is
  # the name of a linked organization page: a member who wrote "DB" and linked
  # the page is otherwise not findable under the name the page carries. Only a
  # **public** page (`organization_public_row/1`, the SQL side of the policy
  # `WorkExperience.linked_organization/1` owns) — a pending claim or a frozen
  # page shows its name nowhere, so it must not answer a search either.
  defp field_queries(:organization, pattern) do
    [
      from(w in WorkExperience, where: ilike(w.organization, ^pattern), select: w.user_id),
      from(w in WorkExperience,
        join: o in Organization,
        on: o.id == w.organization_id and organization_public_row(o),
        where: ilike(o.name, ^pattern),
        select: w.user_id
      )
    ]
  end

  # The institution, never the degree or the subject: the checkbox names a
  # place, and a box labelled "School" that answers "Computer Science" is a
  # different search than the one the reader ticked.
  defp field_queries(:school, pattern) do
    [from(e in Education, where: ilike(e.school, ^pattern), select: e.user_id)]
  end

  defp field_queries(field, pattern) do
    [from(u in User, where: ilike(field(u, ^field), ^pattern), select: u.id)]
  end

  @doc """
  The CV entry each of `users` was matched on, as `%{user_id => entry}` — a
  `%Vutuv.Profiles.WorkExperience{}` or a `%Vutuv.Profiles.Education{}`. Empty
  unless a CV field is ticked and the query answers.

  A listing row shows a member's **current** job, which explains nothing when
  the search found them through a role they left in 2016 or a university they
  attended: the row would name a company the query never mentioned, and the
  reader is left to guess why the member is in the list at all. So a search
  that ticks a CV field asks, for the handful of members it actually renders,
  which entry answered it.

  One query per ticked CV field over the rendered ids — never one per row, the
  contract every listing map here keeps (`UserHelpers.work_information_map/2`)
  — with the narrow projection those rows need, because `description` is a
  `text` column that LinkedIn imports fill to 10k characters.

  The entry that wins is the one matching the **most** words of the query (so
  "siemens healthineers" prefers the Healthineers role over an older plain
  Siemens one), then the most recent (a running role before an ended one), work
  before education, and the id last so the answer never depends on the plan.
  """
  def matched_entries(users, query, fields \\ @search_fields)

  def matched_entries([], _query, _fields), do: %{}

  def matched_entries(users, query, fields) do
    {cv_fields, name_fields} = Enum.split_with(parse_search_fields(fields), &(&1 in @cv_fields))

    with [_ | _] <- cv_fields,
         needle when is_binary(needle) <- query |> cap() |> normalize_search(),
         [_ | _] = words <- String.split(needle, ~r/\s+/, trim: true),
         [_ | _] = ids <- cv_explained_ids(users, words, name_fields) do
      cv_fields
      |> Enum.flat_map(&cv_matches(&1, ids, words))
      |> Enum.group_by(& &1.user_id)
      |> Map.new(fn {user_id, matches} -> {user_id, best_match(matches, words)} end)
    else
      _ -> %{}
    end
  end

  # The members whose row a CV entry may take over: the ones the ticked **name**
  # fields cannot already account for.
  #
  # `search/3` requires every word to match some ticked field, while the match
  # line is allowed to settle for any word — otherwise "vergangen siemens",
  # which spans a surname and an employer, would explain nothing. That slack is
  # what makes this filter necessary: somebody looking up "Anna" would otherwise
  # have her row taken over by the "Annapurna Trekking GmbH" she left in 2008,
  # which is not what was searched for. If the names alone cover every word, the
  # names are the explanation.
  #
  # With no name field ticked `names_cover?/3` is false for every member (no
  # field can carry a word), so every row is a candidate and no clause is needed
  # to say so.
  defp cv_explained_ids(users, words, name_fields) do
    users
    |> Enum.reject(&names_cover?(&1, words, name_fields))
    |> Enum.map(& &1.id)
  end

  defp names_cover?(user, words, name_fields) do
    Enum.all?(words, fn word ->
      Enum.any?(name_fields, &SearchText.contains?(Map.get(user, &1), word))
    end)
  end

  # The best of a member's matching entries, and the only place the preference
  # order lives. One candidate is the common case and needs no comparison.
  defp best_match([only], _words), do: only.entry
  defp best_match(matches, words), do: Enum.min_by(matches, &rank(&1, words)).entry

  # What `Organizations.public_visible?/1` reads, plus the name the line prints:
  # enough for `WorkExperience.linked_organization/1` to answer, and no more.
  @page_line_fields ~w(id name status frozen_at)a
  @education_line_fields ~w(id user_id school degree start_month start_year end_month end_year)a

  defp cv_matches(:organization, ids, words) do
    from(w in WorkExperience,
      left_join: o in Organization,
      on: o.id == w.organization_id and organization_public_row(o),
      where: w.user_id in ^ids,
      where: ^any_word(words, &dynamic([w, o], ilike(w.organization, ^&1) or ilike(o.name, ^&1))),
      select: {struct(w, ^WorkExperience.line_fields()), struct(o, ^@page_line_fields)}
    )
    |> Repo.all()
    |> Enum.map(fn {job, page} ->
      # The page rides along in the association it belongs to, so the view names
      # the employer through `WorkExperience.linked_organization/1` like every
      # other surface rather than deciding for itself, and `match_text/1` below
      # ranks on both names the query could have matched. A left join with no
      # match selects `nil`, which that policy already reads as "not linked".
      job = %{job | organization_page: page}

      %{user_id: job.user_id, entry: job, field: :organization}
    end)
  end

  defp cv_matches(:school, ids, words) do
    from(e in Education,
      where: e.user_id in ^ids,
      where: ^any_word(words, &dynamic([e], ilike(e.school, ^&1))),
      select: struct(e, ^@education_line_fields)
    )
    |> Repo.all()
    |> Enum.map(&%{user_id: &1.user_id, entry: &1, field: :school})
  end

  # Any word, unlike the search itself: an entry that carries one word of the
  # query is a candidate for the line, and the ranking decides between them.
  # The member is in the result set because *every* word matched something.
  defp any_word(words, clause) do
    Enum.reduce(words, dynamic(false), fn word, acc ->
      dynamic(^acc or ^clause.(contains(word)))
    end)
  end

  # Smaller is better, so the whole preference order is one comparable tuple.
  # The field's position in `@cv_fields` is what puts work before education.
  defp rank(%{entry: entry, field: field} = match, words) do
    {
      -word_hits(match_text(match), words),
      Enum.find_index(@cv_fields, &(&1 == field)),
      if(is_nil(entry.end_year), do: 0, else: 1),
      -(entry.end_year || 0),
      -(entry.start_year || 0),
      entry.id
    }
  end

  # What the database matched on, derived rather than carried: both names an
  # employer can be known by, or the institution.
  defp match_text(%{field: :organization, entry: job}) do
    Enum.join([job.organization, job.organization_page && job.organization_page.name], " ")
  end

  defp match_text(%{field: :school, entry: education}), do: education.school

  defp word_hits(text, words), do: Enum.count(words, &SearchText.contains?(text, &1))

  @doc """
  One entry per bucket — a-z, then `other` — as `%{letter: letter, count: n}`,
  zero-count letters included so the overview can render the full strip.
  """
  def letter_entries do
    counts =
      listed_users()
      |> group_by([u], letter_bucket(u))
      |> select([u], {letter_bucket(u), count(u.id)})
      |> Repo.all()
      |> Map.new()

    for letter <- @letters ++ [@other] do
      %{letter: letter, count: Map.get(counts, bucket_key(letter), 0)}
    end
  end

  @doc "The directory's member total: the sum of `letter_entries/0`."
  def total(entries), do: Enum.sum_by(entries, & &1.count)

  @doc """
  One page of a letter's members as `%{users: users, total: total}`, sorted
  by last name then first name (id as the creation-order tiebreaker), paged
  by the `?page` param like every browse page (`Vutuv.Pages`) at
  `per_page/0` members per page.
  """
  def members_page(letter, params) do
    base = where(listed_users(), [u], letter_bucket(u) == ^bucket_key(letter))
    total = Repo.aggregate(base, :count)

    users =
      base
      |> filed_order()
      |> Pages.paginate(params, total, @per_page)
      |> Repo.all()
      |> Images.preload_member_images()

    %{users: users, total: total}
  end

  defp bucket_key(@other), do: "#"
  defp bucket_key(letter), do: letter
end
