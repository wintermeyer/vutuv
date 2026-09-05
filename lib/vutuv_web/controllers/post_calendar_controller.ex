defmodule VutuvWeb.PostCalendarController do
  @moduledoc """
  The public post calendar: `/system/posts` is the overview of every month
  that has posts, `/system/posts/:year/:month` one month as a calendar grid,
  and `/system/posts/:year/:month/:day` the posts written on that day.

  It is to the posts what `VutuvWeb.DirectoryController` is to the members: a
  browsable index for people, and the crawl surface for search engines that
  follow links instead of reading `/sitemap.xml`. Until it existed, nothing on
  the site linked to the post of somebody you do not already follow — the feed
  is login-only and the landing page shows screenshots — so a crawler that
  never fetched the sitemap never met one.

  A row is listed for every post anybody may read, and only a post whose author
  is open to search engines carries its permalink and its first line
  (`Vutuv.PostCalendar.crawlable?/1`, the set `Vutuv.Sitemap` advertises). Also
  served as Markdown / text / JSON / XML; keep the templates and the doc
  builders in sync (`agent_docs_drift_test.exs`).
  """

  use VutuvWeb, :controller

  import VutuvWeb.UI, only: [month_name: 1]

  alias Vutuv.Identity
  alias Vutuv.PostCalendar
  alias Vutuv.Posts
  alias Vutuv.ViewerClock
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.PostTeaser

  def index(conn, _params) do
    months = PostCalendar.month_counts()
    title = gettext("Post calendar")
    # The page's one sentence, said once and handed to both renderings: the
    # HTML prints it under the heading and the documents carry it as their
    # `description`, so the two cannot describe this page differently.
    description = gettext("Every public post on vutuv, filed under the day it was written.")

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html", page_title: title, description: description, months: months)
      end,
      doc: fn -> ListDocs.build_post_calendar_index(months, title, description) end
    )
  end

  def month(conn, %{"year" => year, "month" => month}) do
    case PostCalendar.parse_date(year, month) do
      {:ok, date} -> show_month(conn, date)
      :error -> ControllerHelpers.render_error(conn, 404)
    end
  end

  defp show_month(conn, date) do
    counts = PostCalendar.day_counts(date)
    title = gettext("Posts in %{month} %{year}", month: month_name(date.month), year: date.year)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "month.html",
          page_title: title,
          title: title,
          month: date,
          counts: counts,
          # The neighbouring months, so a crawler (and a reader) can walk the
          # archive month by month without going back to the overview. Only
          # months that have something in them, and never into the future.
          neighbours: PostCalendar.neighbour_months(date)
        )
      end,
      doc: fn -> ListDocs.build_post_calendar_month(date, counts) end
    )
  end

  def day(conn, %{"year" => year, "month" => month, "day" => day} = params) do
    case PostCalendar.parse_date(year, month, day) do
      {:ok, date} -> show_day(conn, date, params)
      :error -> ControllerHelpers.render_error(conn, 404)
    end
  end

  defp show_day(conn, date, params) do
    %{posts: posts, total: total} = PostCalendar.day_page(date, params)
    entries = Enum.map(posts, &entry/1)
    title = gettext("Posts on %{date}", date: ViewerClock.format(date, :date))

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "day.html",
          page_title: title,
          title: title,
          day: date,
          entries: entries,
          total: total,
          per_page: PostCalendar.per_page()
        )
      end,
      doc: fn -> ListDocs.build_post_calendar_day(date, entries, total) end
    )
  end

  # One row of a day, built once and handed to both the template and the doc
  # builder, so the two cannot disagree about which post was linked. The author
  # travels as the identity itself, so each rendering asks it for what it needs
  # (`Identity.path/1` for the page's link, `Identity.ref/1` for the document's
  # author object) instead of being handed a flattened copy.
  #
  # A post whose author is not open to search engines keeps its place in the day
  # — the count would otherwise be short — and loses the two things that would
  # carry it into an index anyway: `path` is nil, so nothing links it, and its
  # own first line gives way to the line saying why. One nil decides both, in
  # both renderings.
  defp entry(post) do
    author = Posts.author(post)

    if Identity.indexable?(author) do
      %{id: post.id, author: author, path: Posts.path(post), text: teaser(post)}
    else
      %{
        id: post.id,
        author: author,
        path: nil,
        text: gettext("Post not open to search engines")
      }
    end
  end

  # `PostTeaser.plain_line/2` answers `""` for a post with no words in it — a
  # photograph, a lone video — and an empty string is a link with nothing to
  # click. Such a post says what it is instead.
  defp teaser(post) do
    case PostTeaser.plain_line(post) do
      "" -> gettext("Post without text")
      line -> line
    end
  end
end
