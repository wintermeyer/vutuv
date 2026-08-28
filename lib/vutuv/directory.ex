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
  arriving with a name in mind actually types.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query
  import Vutuv.SearchText, only: [contains: 1, normalize_search: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Pages
  alias Vutuv.Repo

  @letters Enum.map(?a..?z, &<<&1>>)

  # The URL segment of the non-letter bucket; SQL spells it "#".
  @other "other"

  # Deliberately denser than the site-wide 250 (`Vutuv.Pages.max_page_items/0`):
  # a directory page is browsed, not scanned once, so short pages with a
  # visible pager beat one endless scroll.
  @per_page 50

  # What the search box looks in, in checkbox order. Also the allowlist the
  # `fields` param is read through — never `String.to_atom/1` on a URL value.
  @search_fields [:first_name, :last_name, :username]

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
  Members whose selected name fields contain `query`: a case-insensitive
  substring in each field, OR-ed across the fields, so "mei" finds Meier and
  Meierhoff and a search across all three finds somebody by whichever of their
  names the searcher happens to remember. With both name fields selected the
  **whole name** matches too ("anna mei"), because that is what a person with a
  name in mind types and matching it per column would find nothing.

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
    with needle when is_binary(needle) <- normalize_search(query),
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
    do: %{users: Enum.map(rows, &elem(&1, 0)), total: total}

  # "Zabel, Anna" before "Zabel, Zoe", with the id (creation order, UUID v7) as
  # the tiebreaker. One definition for the letter pages and the search, so a
  # result can never be filed differently from the page it would be browsed on.
  defp filed_order(query),
    do: order_by(query, [u], asc: name_sort_key(u), asc: u.first_name, asc: u.id)

  # Every word of the query has to match **some** selected column: "anna mei"
  # finds Anna Meier because "anna" matches a first name and "mei" a last one.
  # A one-word query is the same single OR it always was.
  #
  # The obvious alternative — matching the query against `first || ' ' || last`,
  # which is what `SearchText.name_ilike/3` adds and what the admin browser and
  # the composer's typeahead use — was measured and rejected here: a
  # concatenation is an expression, no trigram index covers it, and one such arm
  # in the OR turns the whole query back into a sequential scan (18.5 ms against
  # 0.36 ms on today's ~6,000 rows). Splitting into words keeps every arm a bare
  # column ILIKE, so the plan stays a BitmapAnd over BitmapOrs — and it matches
  # "meier anna" too, which the concatenation never could.
  defp field_match(fields, needle) do
    needle
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(dynamic(true), fn word, acc ->
      dynamic([u], ^acc and ^any_field_match(fields, contains(word)))
    end)
  end

  # OR across the selected columns, built as a dynamic so the field list stays
  # data rather than a query per combination. `fields` arrives already through
  # `parse_search_fields/1`, so "no field" can never reach the query as
  # `where: false`.
  defp any_field_match(fields, pattern) do
    Enum.reduce(fields, dynamic(false), fn field, acc ->
      dynamic([u], ^acc or ilike(field(u, ^field), ^pattern))
    end)
  end

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

    %{users: users, total: total}
  end

  defp bucket_key(@other), do: "#"
  defp bucket_key(letter), do: letter
end
