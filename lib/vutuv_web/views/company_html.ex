defmodule VutuvWeb.CompanyHTML do
  @moduledoc """
  The two company pages: `/system/investors` and `/system/media-kit`.

  The media kit is **English only** in every locale and so goes through no
  gettext; the investor page follows the reader's language and takes every
  sentence of its argument from `VutuvWeb.AgentDocs.InvestorsDoc`, so the HTML
  and the four agent formats cannot drift apart. See `VutuvWeb.CompanyController`
  for why the two pages differ.
  """
  use VutuvWeb, :html

  alias Vutuv.PeopleHistory
  alias Vutuv.PeopleHistory.Snapshot
  alias Vutuv.ViewerClock
  alias VutuvWeb.AgentDocs.InvestorsDoc

  embed_templates("../templates/company/*")

  @doc """
  One of the investor page's figure tiles. Kept beside the page's other shared
  bits rather than in the template so every figure is grouped the same way.
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, default: nil)

  def figure_tile(assigns) do
    ~H"""
    <%!-- `min-w-0`: a grid item defaults to `min-width: auto`, so it refuses to
          shrink below its longest word and pushes the whole row wider than the
          screen. Two tiles side by side on a 390px phone is exactly where that
          bites, and a page that scrolls sideways is a bug. --%>
    <div class="min-w-0 rounded-xl bg-slate-50 p-4 dark:bg-slate-800/60">
      <p class="text-2xl font-bold text-slate-900 dark:text-white">{@value}</p>
      <p class="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400">
        {@label}
      </p>
      <p :if={@note} class="mt-1 text-xs text-slate-600 dark:text-slate-400">{@note}</p>
    </div>
    """
  end

  @doc """
  The growth curve: the people total (`Vutuv.PeopleHistory.series/0`, members
  plus the Fediverse accounts following them) per day, which is the very figure
  the top bar shows.

  The vertical axis is the span the data actually covers rather than zero to
  peak, and the caption names both ends so the zoom cannot mislead: over six
  weeks a head count in the thousands moves by a couple of hundred, and an axis
  from zero draws that as a solid block with a flat lid.

  Renders nothing for a series too short to be a curve (fewer than two days) or
  one that never moves: an empty chart frame says less than no chart at all.
  """
  attr(:series, :list, required: true)

  attr(:class, :string, default: "", doc: "wrapper spacing, where the caller wants any")

  attr(:height, :string,
    default: "h-32",
    doc: "how tall the plot is; taller where it stands beside the tiles rather than under them"
  )

  def growth_curve(assigns) do
    assigns = assign(assigns, :geometry, curve_geometry(assigns.series))

    ~H"""
    <figure :if={@geometry} class={@class}>
      <svg
        viewBox="0 0 600 140"
        preserveAspectRatio="none"
        role="img"
        aria-label={
          gettext("People here per day over the last %{days} days", days: @geometry.days)
        }
        class={["w-full", @height]}
      >
        <polygon points={@geometry.area} class="fill-brand-600/10 dark:fill-brand-400/10" />
        <%!-- `vector-effect` keeps the line an even 2px once the viewBox is
              stretched to the card, which `preserveAspectRatio="none"` does. --%>
        <polyline
          points={@geometry.line}
          fill="none"
          stroke-width="2"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
          class="stroke-brand-600 dark:stroke-brand-400"
        />
      </svg>
      <%!-- The two ends of the line as numbers, because the vertical axis does
            NOT start at zero: over six weeks a head count in the thousands moves
            by a couple of hundred, and an axis from zero draws that as a solid
            block with a flat lid. Naming both figures is what keeps the zoom
            honest — the reader can see the span the line is drawn across. --%>
      <figcaption class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-slate-600 dark:text-slate-400">
        <span>{@geometry.first_value} → {@geometry.last_value}</span>
        <span>{@geometry.first_day} → {@geometry.last_day}</span>
      </figcaption>
    </figure>
    """
  end

  # The line and the wash under it as SVG point lists, plus what the caption
  # needs. `nil` where there is nothing to draw.
  #
  # The line itself comes from `Vutuv.PeopleHistory.curve_points/3`, in the
  # module that owns the rows; what stays here is what only this chart has, the
  # wash under the line and the two end figures.
  #
  # One line, the people total the top bar shows, rather than the two stacked
  # bands the two columns invite: the member half is two orders of magnitude
  # larger than the Fediverse half, so on any shared scale the smaller band is a
  # hairline along the top and says nothing. Which half moved is in the sentence
  # under the chart instead, where it can be said in words.
  defp curve_geometry(series) do
    if line_points = PeopleHistory.curve_points(series, 600, 140) do
      first = List.first(series)
      last = List.last(series)

      %{
        line: line_points,
        # The wash is the same line closed along the floor, so it costs a
        # suffix rather than a second pass over ninety points.
        area: line_points <> " 600.0,140.0 0.0,140.0",
        days: Date.diff(last.day, first.day),
        first_day: ViewerClock.format(first.day, :short_date),
        last_day: ViewerClock.format(last.day, :short_date),
        first_value: delimited_count(Snapshot.total(first)),
        last_value: delimited_count(Snapshot.total(last))
      }
    end
  end
end
