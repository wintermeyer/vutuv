defmodule Vutuv.Directory do
  @moduledoc """
  The public member directory (`/system/members`): the one definition of the
  **crawlable member set** — activated members who have not opted out of
  search engines (`noindex?: false`) and are not moderation-hidden — grouped
  alphabetically for browsing. `Vutuv.Sitemap` advertises the same set to
  crawlers, so a member appears in the directory exactly when their profile
  is in the sitemap.

  Members are filed by **last name** (first name only as a fallback), with
  accents folded into their base letter so Özil sorts under O (DIN 5007);
  names that start with no letter at all share the `"other"` bucket. The
  bucket expression lives in SQL so the letter pages paginate in the
  database (`Vutuv.Pages`), like every other browse page.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  @letters Enum.map(?a..?z, &<<&1>>)

  # The URL segment of the non-letter bucket; SQL spells it "#".
  @other "other"

  # Deliberately denser than the site-wide 250 (`Vutuv.Pages.max_page_items/0`):
  # a directory page is browsed, not scanned once, so short pages with a
  # visible pager beat one endless scroll.
  @per_page 50

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
  The crawlable member set: activated, indexable (`noindex?: false`), not
  moderation-hidden. The shared base of the directory pages and the
  sitemap's member/post entries (`Vutuv.Sitemap`).
  """
  def indexable_users do
    # account_confirmed_row/1 is the shared confirmed-member gate every other
    # listing query uses: it treats a legacy NULL flag as confirmed, so the
    # crawlable set matches the rest of the app rather than hand-rolling a
    # stricter `u.email_confirmed?` test here.
    from(u in User,
      where: account_confirmed_row(u) and not u.noindex? and not account_hidden_row(u)
    )
  end

  @doc """
  One entry per bucket — a-z, then `other` — as `%{letter: letter, count: n}`,
  zero-count letters included so the overview can render the full strip.
  """
  def letter_entries do
    counts =
      indexable_users()
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
    base = where(indexable_users(), [u], letter_bucket(u) == ^bucket_key(letter))
    total = Repo.aggregate(base, :count)

    users =
      base
      |> order_by([u], asc: name_sort_key(u), asc: u.first_name, asc: u.id)
      |> Vutuv.Pages.paginate(params, total, @per_page)
      |> Repo.all()

    %{users: users, total: total}
  end

  defp bucket_key(@other), do: "#"
  defp bucket_key(letter), do: letter
end
