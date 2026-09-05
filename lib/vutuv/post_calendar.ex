defmodule Vutuv.PostCalendar do
  @moduledoc """
  The queries behind the public post calendar (`/system/posts`): every public
  post, filed under the day it was written, so a reader — or a crawler that
  follows links rather than reading `/sitemap.xml` — can walk the whole archive
  from one page in the footer.

  It is the posts' `Vutuv.Directory`. The member directory answers "who is
  filed under M"; this one answers "what was written on 17 March", and it
  exists for the same reason: `/sitemap.xml` lists every post permalink, but
  nothing on the site *links* to a post of somebody you do not already follow,
  so a crawler that never fetches the sitemap never meets one. The calendar is
  the link path.

  ## Two sets, one rule

  `listed_posts/0` is what the calendar shows and counts: posts anybody may
  read (`Vutuv.Posts.scope_visible/2` with no viewer — no denials, not frozen,
  author not moderation-hidden) whose author is a confirmed member or a
  publicly visible page.

  Narrower is the set whose **permalink is linked** and whose first line is
  quoted, and that question is not asked here: it is
  `Vutuv.Identity.indexable?/1`, the one owner of "is this author open to
  crawlers", which `Vutuv.Sitemap` asks as SQL over the same two flags
  (`noindex?` on a member, `seo?` on a page). A calendar that linked a post the
  sitemap withholds would walk a crawler straight around the member's opt-out.
  The row itself stays: without it a day would claim fewer posts than were
  written on it.

  The day is `posts.published_on`, the German calendar day at insert time
  (`Vutuv.BerlinTime`), never moved by an edit — the same column the author
  archive at `/:slug/posts/2026/03/17` files by, so a post sits under the same
  date in both places.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_confirmed_row: 1]
  import Vutuv.Organizations.Query, only: [organization_public_row: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  # The member directory's page size rather than the site-wide 250: a day page
  # is browsed, and a shorter page with a visible pager beats one long scroll.
  @per_page 50

  @doc "How many posts one day page holds before the pager takes over."
  def per_page, do: @per_page

  @doc """
  One entry per month that has posts, newest first, as
  `%{year: y, month: m, count: n}`.

  Only months that have something in them: an empty month is a muted tile on
  the overview, and there is nothing to count for it.
  """
  def month_counts do
    # `::date` in the fragment rather than a bare `date_trunc`: without the cast
    # Postgres answers a timestamp and Postgrex hands back a NaiveDateTime,
    # which is a different shape for the same thing. The cast makes the column
    # what it already is, a calendar month's first day.
    listed_posts()
    |> group_by([p], fragment("date_trunc('month', ?)::date", p.published_on))
    |> order_by([p], desc: fragment("date_trunc('month', ?)::date", p.published_on))
    |> select([p], {fragment("date_trunc('month', ?)::date", p.published_on), count(p.id)})
    |> Repo.all()
    |> Enum.map(fn {%Date{year: year, month: month}, count} ->
      %{year: year, month: month, count: count}
    end)
  end

  @doc """
  The post count per day of one month, as a `%{Date.t() => count}` map — what
  the month grid shades its cells from, and what decides which of them is a
  link.
  """
  def day_counts(%Date{} = month) do
    first = Date.beginning_of_month(month)

    listed_posts()
    |> where([p], p.published_on >= ^first and p.published_on <= ^Date.end_of_month(first))
    |> group_by([p], p.published_on)
    |> select([p], {p.published_on, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  One page of a day's posts as `%{posts: posts, total: total}`, oldest first
  (the order they were written in — the id is a UUID v7, so its order is
  creation order), paged by the `?page` param at `per_page/0` posts.

  Both author associations are preloaded, because every row needs its author's
  name, its permalink (`Vutuv.Posts.path/1`) and the search-engine flag that
  decides whether it gets one.
  """
  def day_page(%Date{} = date, params) do
    base = where(listed_posts(), [p], p.published_on == ^date)
    total = Repo.aggregate(base, :count)

    posts =
      base
      |> order_by([p], asc: p.id)
      |> Pages.paginate(params, total, @per_page)
      |> preload([:user, :organization])
      |> Repo.all()

    %{posts: posts, total: total}
  end

  @doc """
  The nearest month before and after `month` that has posts, as
  `%{previous: date | nil, next: date | nil}` (each at its first day).

  The month-to-month chain the grid pages along. It steps to the nearest month
  with something in it rather than to the literal neighbour, so a gap in the
  archive is one click rather than a run of empty pages a crawler has to walk
  (and it is what makes the arrows honest at the two ends).
  """
  def neighbour_months(%Date{} = month) do
    first = Date.beginning_of_month(month)

    %{
      previous: edge_month(dynamic([p], p.published_on < ^first), :desc),
      next: edge_month(dynamic([p], p.published_on > ^Date.end_of_month(first)), :asc)
    }
  end

  defp edge_month(condition, direction) do
    listed_posts()
    |> where(^condition)
    |> order_by([p], [{^direction, p.published_on}])
    |> limit(1)
    |> select([p], p.published_on)
    |> Repo.one()
    |> case do
      %Date{} = date -> Date.beginning_of_month(date)
      nil -> nil
    end
  end

  @doc """
  The `:year/:month[/:day]` segments of a calendar URL as a `Date`, or
  `:error` — the month pages pass no day and get that month's first.

  One function for both levels, and the same bounds the author archive's
  `/:slug/posts/2026/03/17` uses (`VutuvWeb.PostController`): a four-digit year,
  and `Date.new/3` for the rest, so it need not know about February. Two
  spellings of "which archive URL exists" would eventually answer differently
  for the same date.
  """
  def parse_date(year, month, day \\ "1") do
    with {:ok, year} when year in 1000..9999 <- integer(year),
         {:ok, month} <- integer(month),
         {:ok, day} <- integer(day),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _invalid -> :error
    end
  end

  # A bare `String.to_integer/1` raises on anything else, and these segments are
  # whatever the URL says. Trailing characters are rejected too ("3x" is not a
  # month), so one spelling of a month reaches the canonical URL.
  defp integer(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _not_a_number -> :error
    end
  end

  @doc """
  The posts the calendar lists: readable by anybody, by an author the site
  shows publicly.

  Left joins with an explicit branch per author kind, never an inner join to
  `users`: a post published in a page's name carries `user_id: nil`, and an
  inner join drops every one of them without a word (issues #1334/#1336).
  """
  def listed_posts do
    Post
    |> Posts.scope_visible(nil)
    |> join(:left, [p], u in User, on: u.id == p.user_id)
    |> join(:left, [p], o in Organization, on: o.id == p.organization_id)
    |> where(
      [p, u, o],
      (not is_nil(p.user_id) and account_confirmed_row(u)) or
        (not is_nil(p.organization_id) and organization_public_row(o))
    )
  end
end
