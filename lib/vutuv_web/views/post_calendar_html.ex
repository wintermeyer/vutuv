defmodule VutuvWeb.PostCalendarHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Identity
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.FeedTimeTravel

  embed_templates("../templates/post_calendar/*")

  @doc """
  One tile of a calendar grid: a link when there is something behind it, a
  muted square when there is not.

  All three shapes on this page are the same tile — a month on the overview, a
  day in the month grid, a day from a neighbouring month at the edges of it —
  so the Tailwind strings live here instead of being written out twice across
  two templates. `key` + `count` become the `data-` pair the tests read;
  `faded` is the neighbouring-month cell, dimmer still and carrying no data
  because it belongs to another page.
  """
  attr(:href, :any, default: nil, doc: "nil renders the muted square instead of a link")
  attr(:key, :string, default: nil)
  attr(:count, :integer, default: 0)
  attr(:label, :string, required: true)
  attr(:title, :string, default: nil)
  attr(:faded, :boolean, default: false)
  attr(:square, :boolean, default: false, doc: "day cells are square, month tiles are not")

  def tile(assigns) do
    ~H"""
    <a
      :if={@href}
      href={@href}
      data-key={@key}
      data-count={@count}
      title={@title}
      class={[
        tile_shape(@square),
        "font-semibold text-brand-700 ring-1 ring-slate-200",
        "hover:bg-brand-50 dark:text-brand-100 dark:ring-slate-800 dark:hover:bg-brand-900/40"
      ]}
    >
      {@label}
    </a>
    <span
      :if={!@href}
      data-key={@key}
      data-count={@key && "0"}
      class={[
        tile_shape(@square),
        "text-slate-600 dark:text-slate-400",
        !@faded && "font-semibold opacity-40 ring-1 ring-slate-200 dark:ring-slate-800",
        @faded && "opacity-20"
      ]}
    >
      {@label}
    </span>
    """
  end

  defp tile_shape(true), do: "flex aspect-square items-center justify-center rounded-lg text-sm"
  defp tile_shape(false), do: "flex items-center justify-center rounded-lg px-2 py-3 text-sm"

  @doc """
  The six-week grid of a month, as `%{date:, in_month?:}` cells.

  The feed calendar's own grid (`FeedTimeTravel.month_grid/1`), so the two
  calendars on this site put a given day in the same square. That one is a
  LiveView with a heatmap and this one a page of links, but the arithmetic of
  where a month starts is the same arithmetic.
  """
  def month_grid(%Date{} = month), do: FeedTimeTravel.month_grid(month)

  @doc "A calendar day in the reader's own date shape (`Vutuv.ViewerClock`)."
  def viewer_date(%Date{} = date), do: ViewerClock.format(date, :date)

  @doc "The `2026-03` key a month tile carries for the tests to read."
  def month_key(year, month), do: "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"

  @doc "The author's visible name / profile path, whichever kind of author it is."
  def author_name(entry), do: Identity.display_name(entry.author)
  def author_path(entry), do: Identity.path(entry.author)

  @doc """
  The years the overview draws, newest first, each with the twelve months of
  that year and the count the calendar holds for it.

  Built from the counted months rather than from a range of years: a year the
  archive does not reach is one nobody can browse into, so it draws no row at
  all — while a year with a single post in December still shows its full twelve
  tiles, eleven of them muted, because a calendar that skipped them would leave
  the reader guessing whether the months exist.
  """
  def year_rows(months) do
    by_year = Enum.group_by(months, & &1.year)

    by_year
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.map(fn year ->
      counts = Map.new(by_year[year], &{&1.month, &1.count})
      %{year: year, months: Enum.map(1..12, &%{month: &1, count: Map.get(counts, &1, 0)})}
    end)
  end
end
