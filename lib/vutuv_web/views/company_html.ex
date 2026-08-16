defmodule VutuvWeb.CompanyHTML do
  @moduledoc """
  The two company pages: `/system/investors` and `/system/media-kit`.

  Both are **English only** in every locale (see `VutuvWeb.CompanyController`),
  so nothing here goes through `gettext` — a half-translated page reads worse
  than an honestly monolingual one, and the footer labels them in English to
  say so before the click.

  It also owns the investor page's growth curve, drawn as plain server-rendered
  SVG. No chart library: the page is two paths and a handful of labels, and
  shipping a JavaScript bundle for that would cost every reader of every other
  page nothing less than the whole file.
  """
  use VutuvWeb, :html

  alias VutuvWeb.UI

  embed_templates("../templates/company/*")

  # The plotting box, in SVG user units. The chart scales to its container
  # through the viewBox, so these are proportions rather than pixels.
  @width 640
  @height 220
  @pad_left 52
  @pad_right 12
  @pad_top 12
  @pad_bottom 28

  @doc """
  The growth curve: a filled area for the members here and a line above it for
  the people total (members plus the Fediverse accounts following something on
  this installation). The gap between the two IS the Fediverse share, which is
  the only honest way to show a figure two orders of magnitude smaller than the
  one beside it — a second line against the same axis would lie flat on the
  floor, and its own axis would suggest the two are comparable in size.

  **The y-axis starts at zero.** Both figures are running totals in the
  thousands growing by a few a day, so an axis cropped to the data's own range
  would turn a couple of percent into a mountain. That is the one chart trick
  an investor page must not play: the reader who notices is the reader we want.
  """
  attr(:series, :list, required: true)

  def growth_chart(assigns) do
    assigns = assign(assigns, :chart, chart(assigns.series))

    ~H"""
    <figure :if={@chart} class="mt-6">
      <svg
        viewBox={@chart.view_box}
        class="h-auto w-full"
        role="img"
        aria-label={@chart.summary}
        data-growth-chart={length(@series)}
      >
        <title>{@chart.summary}</title>
        <line
          :for={{_label, y} <- @chart.ticks}
          x1={@chart.plot_left}
          x2={@chart.plot_right}
          y1={y}
          y2={y}
          class="stroke-slate-200 dark:stroke-slate-700"
          stroke-width="1"
        />
        <text
          :for={{label, y} <- @chart.ticks}
          x={@chart.plot_left - 8}
          y={y + 4}
          text-anchor="end"
          class="fill-slate-500 text-[11px] dark:fill-slate-400"
        >
          {label}
        </text>
        <path d={@chart.members_area} class="fill-brand-500/25" />
        <path
          d={@chart.members_line}
          fill="none"
          class="stroke-brand-600 dark:stroke-brand-400"
          stroke-width="2"
          stroke-linejoin="round"
        />
        <path
          d={@chart.total_line}
          fill="none"
          class="stroke-accent"
          stroke-width="2"
          stroke-linejoin="round"
        />
        <text
          x={@chart.plot_left}
          y={@chart.label_baseline}
          text-anchor="start"
          class="fill-slate-500 text-[11px] dark:fill-slate-400"
        >
          {@chart.first_day}
        </text>
        <text
          x={@chart.plot_right}
          y={@chart.label_baseline}
          text-anchor="end"
          class="fill-slate-500 text-[11px] dark:fill-slate-400"
        >
          {@chart.last_day}
        </text>
      </svg>
      <figcaption class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-slate-600 dark:text-slate-400">
        <span class="flex items-center gap-2">
          <span class="h-2.5 w-2.5 rounded-full bg-brand-600 dark:bg-brand-400"></span>
          Members on vutuv
        </span>
        <span class="flex items-center gap-2">
          <span class="h-2.5 w-2.5 rounded-full bg-accent"></span>
          Total people, including Fediverse accounts
        </span>
      </figcaption>
    </figure>
    """
  end

  @doc """
  The chart's geometry, or `nil` for a series too short to draw a line through.

  Public because `company_html_test.exs` checks the arithmetic directly: an
  off-by-one in the scaling is invisible in a rendered path string and obvious
  in a coordinate.
  """
  def chart(series) when length(series) < 2, do: nil

  def chart(series) do
    totals = Enum.map(series, &(&1.members + &1.fediverse_accounts))
    members = Enum.map(series, & &1.members)
    top = axis_top(Enum.max(totals))

    %{
      members_area: area_path(members, top, length(series)),
      members_line: line_path(members, top, length(series)),
      total_line: line_path(totals, top, length(series)),
      ticks: ticks(top),
      first_day: format_day(List.first(series).day),
      last_day: format_day(List.last(series).day),
      summary: summary(series),
      view_box: "0 0 #{@width} #{@height}",
      plot_left: @pad_left,
      plot_right: @width - @pad_right,
      label_baseline: @height - 8
    }
  end

  defp summary(series) do
    first = List.first(series)
    last = List.last(series)

    "People on vutuv from #{format_day(first.day)} to #{format_day(last.day)}: " <>
      "#{last.members} members and #{last.fediverse_accounts} Fediverse accounts, " <>
      "up from #{first.members} and #{first.fediverse_accounts}."
  end

  # A round number at or above the peak, so the gridline labels read as figures
  # somebody chose rather than as the maximum of the data. The ladder is fine
  # enough that the curve fills its box: with only [1, 2, 5, 10] a peak of 5,934
  # is drawn against an axis of 10,000 and spends its life in the lower half.
  defp axis_top(peak) when peak <= 0, do: 10

  defp axis_top(peak) do
    magnitude = :math.pow(10, floor(:math.log10(peak))) |> round()

    Enum.find_value([1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10], peak, fn factor ->
      candidate = round(factor * magnitude)
      if candidate >= peak, do: candidate
    end)
  end

  defp ticks(top) do
    Enum.map(0..2, fn step ->
      value = round(top * step / 2)
      {en_count(value), y(value, top)}
    end)
  end

  @doc """
  A grouped count in **English**, whatever locale the request carries.

  Both company pages are English only, and `delimited_count/1` follows the
  active Gettext locale — so a German visitor was shown "5.934" inside an
  English sentence, which to an English reader is not a tidiness problem but a
  different number. The chrome around the page stays in the reader's language;
  only the figures inside the English text are pinned.
  """
  def en_count(n) when is_integer(n) do
    Gettext.with_locale(VutuvWeb.Gettext, "en", fn -> UI.delimited_count(n) end)
  end

  defp line_path(values, top, count) do
    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      "#{command(index)}#{x(index, count)} #{y(value, top)}"
    end)
  end

  # The same line, closed down to the baseline and back, so it fills.
  defp area_path(values, top, count) do
    baseline = y(0, top)

    line_path(values, top, count) <>
      " L#{x(count - 1, count)} #{baseline} L#{x(0, count)} #{baseline} Z"
  end

  defp command(0), do: "M"
  defp command(_), do: "L"

  defp x(index, count) do
    plot_width = @width - @pad_left - @pad_right
    Float.round(@pad_left + index * plot_width / (count - 1), 2)
  end

  defp y(value, top) do
    plot_height = @height - @pad_top - @pad_bottom
    Float.round(@pad_top + plot_height * (1 - value / top), 2)
  end

  defp format_day(%Date{} = day), do: Calendar.strftime(day, "%d %b %Y")

  @doc """
  The figure row above the chart. Kept beside it rather than in the template so
  the page cannot claim a number the curve does not draw.
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, default: nil)

  def figure_tile(assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 p-4 dark:bg-slate-800/60">
      <p class="text-2xl font-bold text-slate-900 dark:text-white">{@value}</p>
      <p class="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-400">
        {@label}
      </p>
      <p :if={@note} class="mt-1 text-xs text-slate-600 dark:text-slate-400">{@note}</p>
    </div>
    """
  end
end
