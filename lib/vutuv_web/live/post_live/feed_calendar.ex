defmodule VutuvWeb.PostLive.FeedCalendar do
  @moduledoc """
  An ordinary month calendar in the feed's right-hand column, with each day
  shaded by how much happened on it, and a click on a day opening that whole
  day in the timeline.

  It answers **which day**, and it is the only feed control that shows where
  the timeline is worth going before you go there. The shading is the point: a
  month of a quiet feed is mostly pale, and the two or three days that are not
  are exactly the days to open.

  Two readings, and they are different questions rather than a filter of one
  another. **Feed** counts what reached the reader, through the same nine
  sources a page is built from (`Vutuv.Posts.feed_activity_by_day/4`), so a day
  the heatmap calls busy really does have a timeline behind it. **My posts**
  counts what the reader published, which is one table and no visibility
  question at all.

  ## A day is a window, not a vantage

  Clicking a date shows that day **from its first minute to its last**
  (`VutuvWeb.Live.FeedTimeTravel.day_cursor/1`), and "Load more" inside it
  stops at the day's own edge instead of sliding into the day before. That
  lower bound rides in the feed cursor, so it survives pagination — which is
  the whole reason a day reads as a day rather than as "this day and all of
  history under it".

  ## Where it lives

  Rendered twice, with different ids: in the rail column on a desktop, and
  above the timeline on a phone, which has no rail column at all. The month
  grid is always six rows so paging through months does not change the card's
  height and shove the rail cards below it up and down.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [month_name: 1, weekday_initials: 0]

  alias VutuvWeb.Live.FeedTimeTravel

  @doc "The two readings the heatmap offers."
  def metrics do
    [
      %{key: "feed", label: gettext("Feed")},
      %{key: "own", label: gettext("My posts")}
    ]
  end

  @doc """
  The month grid, its heatmap and the two controls under it.

  `id` is required because the calendar renders twice, once per breakpoint.
  """
  attr(:id, :string, required: true)
  attr(:open?, :boolean, default: false, doc: "whether the month grid is unfolded")
  attr(:earlier?, :boolean, default: true, doc: "whether the feed reaches back past this month")
  attr(:month, :any, required: true, doc: "the shown month, a Date at its first day")
  attr(:day, :any, default: nil, doc: "the selected day, a Date, or nil")
  attr(:metric, :string, default: "feed")
  attr(:counts, :map, default: %{})
  attr(:capped?, :boolean, default: false)
  attr(:class, :string, default: nil)

  def feed_calendar(assigns) do
    assigns =
      assign(assigns,
        cells: FeedTimeTravel.month_grid(assigns.month),
        today: Vutuv.ViewerClock.today(),
        peak: assigns.counts |> Map.values() |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <%!-- Folded, the card IS a control, so it takes the app's control height
    (`h-10`) instead of whatever its padding and its tallest child add up to. On
    a phone it stands beside the filter button, which is `h-10`, and the two sat
    four pixels apart — eight once the amber "Now" joined the row. A fixed height
    also keeps the line still: it is the same card whether the reader is
    travelling or not. --%>
    <div
      id={@id}
      class={[
        "rounded-2xl bg-white shadow-sm ring-1 dark:bg-slate-900",
        if(@open?, do: "p-4", else: "flex h-10 px-2"),
        @day && "ring-amber-400 dark:ring-amber-500/60",
        !@day && "ring-slate-200 dark:ring-slate-800",
        @class
      ]}
    >
      <%!-- ONE row in both states, because two would not line up with anything
      else in the column: the fold toggle IS the month (or, folded, the day), so
      the centre of the row never moves and only the month arrows come and go
      around it.

      Folded, this is the whole card and the only thing a reader who never
      travels ever sees: which day the timeline is showing, and a way in.

      Folded the row is the card's only child and stretches to its full height,
      so the fold toggle takes the whole 40px rather than the 28px its own
      padding gives it — the tap target a phone control owes a finger. It
      stretches unconditionally: unfolded the row is as tall as the month arrows
      beside it, which is exactly the toggle's own height, so there is nothing
      to stretch to and the class can stay a static string. --%>
      <div class="flex w-full items-center gap-0.5">
        <.month_arrow
          :if={@open?}
          n={-12}
          label={gettext("Previous year")}
          wide
          disabled={!@earlier?}
        />
        <.month_arrow :if={@open?} n={-1} label={gettext("Previous month")} disabled={!@earlier?} />

        <button
          type="button"
          phx-click="cal-toggle"
          aria-expanded={to_string(@open?)}
          class="flex min-w-0 flex-1 self-stretch items-center justify-center gap-1.5 rounded-lg px-1 py-1 hover:bg-slate-50 dark:hover:bg-slate-800"
        >
          <.calendar_glyph travelling?={!is_nil(@day)} />

          <span class="min-w-0 truncate text-sm font-semibold text-slate-900 tabular-nums dark:text-slate-100">
            <%= if @open? do %>
              {month_name(@month.month)} {@month.year}
            <% else %>
              {Vutuv.ViewerClock.format(@day || @today, :date)}
            <% end %>
          </span>

          <svg
            class={["h-4 w-4 shrink-0 text-slate-400", @open? && "rotate-180"]}
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="2"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
          </svg>
        </button>

        <.month_arrow
          :if={@open?}
          n={1}
          label={gettext("Next month")}
          disabled={at_this_month?(@month)}
        />
        <.month_arrow
          :if={@open?}
          n={12}
          label={gettext("Next year")}
          wide
          disabled={at_this_month?(@month)}
        />

        <%!-- Folded and away from today, the way back has to be on the one line
        there is. Unfolded it sits below, beside the legend, where there is room
        and the arrows already fill this row. --%>
        <.now_button :if={!@open? && @day} />
      </div>

      <%!-- The same seven headings the ad booking calendar has always drawn
      (`VutuvWeb.UI.weekday_initials/0`), already translated in every locale
      this site ships. --%>
      <div
        :if={@open?}
        class="mt-3 grid grid-cols-7 gap-1 text-center text-[10px] font-semibold uppercase text-slate-400 dark:text-slate-500"
      >
        <span :for={initial <- weekday_initials()}>{initial}</span>
      </div>

      <div :if={@open?} class="mt-1 grid grid-cols-7 gap-1">
        <button
          :for={cell <- @cells}
          type="button"
          phx-click="cal-day"
          phx-value-date={Date.to_iso8601(cell.date)}
          disabled={Date.compare(cell.date, @today) == :gt}
          title={day_title(cell.date, Map.get(@counts, cell.date, 0), @metric)}
          aria-current={@day && cell.date == @day && "date"}
          class={[
            "relative flex aspect-square items-center justify-center rounded text-[11px] tabular-nums",
            "disabled:cursor-not-allowed disabled:opacity-30",
            heat_class(Map.get(@counts, cell.date, 0), @peak),
            !cell.in_month? && "opacity-40",
            @day && cell.date == @day && "ring-2 ring-amber-500",
            cell.date == @today && (!@day || cell.date != @day) &&
              "ring-1 ring-slate-400 dark:ring-slate-500"
          ]}
        >
          {cell.date.day}
        </button>
      </div>

      <div :if={@open?} class="mt-3 flex gap-1 rounded-full bg-slate-100 p-1 dark:bg-slate-800">
        <button
          :for={m <- metrics()}
          type="button"
          phx-click="cal-metric"
          phx-value-metric={m.key}
          aria-pressed={to_string(m.key == @metric)}
          class={[
            "h-8 flex-1 rounded-full text-[11px] font-semibold",
            m.key == @metric &&
              "bg-white text-slate-900 shadow-sm dark:bg-slate-900 dark:text-slate-100",
            m.key != @metric &&
              "text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"
          ]}
        >
          {m.label}
        </button>
      </div>

      <div :if={@open?} class="mt-2 flex items-center justify-between gap-2">
        <%!-- The scale, so a shade means something. Without it a pale month and
        a busy one look the same to somebody who has not seen the other. --%>
        <div class="flex items-center gap-1 text-[10px] text-slate-500 dark:text-slate-400">
          <%!-- Their own context, not the bare "More" the notifications page
          uses for a show-more control: here the word is one END OF A SCALE, and
          a msgid is a key rather than a phrase. --%>
          <span>{pgettext("heatmap scale", "Less")}</span>
          <span :for={level <- 0..4} class={["h-3 w-3 rounded-sm", heat_level_class(level)]}></span>
          <span>{pgettext("heatmap scale", "More")}</span>
        </div>

        <.now_button :if={@day} />
      </div>

      <%!-- Said out loud rather than left to look like a quiet month: past the
      cap the counts are a floor, and a heatmap that silently under-reports is
      worse than one that admits it. --%>
      <p :if={@open? && @capped?} class="mt-2 text-[10px] text-slate-500 dark:text-slate-400">
        {gettext("Busy month: the shading counts at least this much.")}
      </p>
    </div>
    """
  end

  # The way back to the present. Rendered folded (beside the date) and unfolded
  # (beside the legend); it was the same markup twice, differing only in a type
  # size nobody had chosen on purpose.
  defp now_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="travel-now"
      class="h-8 shrink-0 rounded-lg bg-amber-600 px-3 text-xs font-semibold text-white hover:bg-amber-700"
    >
      {gettext("Now")}
    </button>
    """
  end

  attr(:n, :integer, required: true)
  attr(:label, :string, required: true)
  attr(:wide, :boolean, default: false)
  attr(:disabled, :boolean, default: false)

  defp month_arrow(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="cal-month"
      phx-value-n={@n}
      disabled={@disabled}
      title={@label}
      aria-label={@label}
      class="inline-flex h-7 w-6 shrink-0 items-center justify-center rounded text-slate-600 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:bg-transparent dark:text-slate-300 dark:hover:bg-slate-800"
    >
      <svg
        class="h-4 w-4"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="2"
        stroke="currentColor"
        aria-hidden="true"
      >
        <path
          :if={@n < 0}
          stroke-linecap="round"
          stroke-linejoin="round"
          d={if(@wide, do: "M18.75 19.5l-7.5-7.5 7.5-7.5m-6 15L5.25 12l7.5-7.5", else: "M15.75 19.5L8.25 12l7.5-7.5")}
        />
        <path
          :if={@n > 0}
          stroke-linecap="round"
          stroke-linejoin="round"
          d={if(@wide, do: "M5.25 4.5l7.5 7.5-7.5 7.5m6-15l7.5 7.5-7.5 7.5", else: "M8.25 4.5l7.5 7.5-7.5 7.5")}
        />
      </svg>
    </button>
    """
  end

  # Amber the moment the timeline is showing some other day. The one failure
  # this feature can produce is a member reading last Tuesday believing it is
  # today, and folded away the calendar has only this to say so with.
  attr(:travelling?, :boolean, required: true)

  defp calendar_glyph(assigns) do
    ~H"""
    <svg
      class={[
        "h-5 w-5 shrink-0",
        if(@travelling?,
          do: "text-amber-600 dark:text-amber-400",
          else: "text-slate-400 dark:text-slate-500"
        )
      ]}
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5"
      />
    </svg>
    """
  end

  defp at_this_month?(month),
    do: Date.compare(month, FeedTimeTravel.month_of(nil)) != :lt

  # Five steps, GitHub's scale, keyed to the busiest day of the month SHOWN
  # rather than to a fixed count. An absolute scale would paint a normal month
  # of a small feed uniformly pale and tell the reader nothing; relative
  # shading answers the question they are actually asking, which is "where in
  # this month did things happen".
  defp heat_class(0, _peak), do: heat_level_class(0)
  defp heat_class(_count, 0), do: heat_level_class(0)

  defp heat_class(count, peak) do
    count |> heat_level(peak) |> heat_level_class()
  end

  defp heat_level(count, peak) do
    cond do
      count >= peak -> 4
      count >= peak * 0.6 -> 3
      count >= peak * 0.3 -> 2
      true -> 1
    end
  end

  defp heat_level_class(0),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400"

  defp heat_level_class(1),
    do: "bg-brand-100 text-brand-800 dark:bg-brand-900/50 dark:text-brand-100"

  defp heat_level_class(2),
    do: "bg-brand-300 text-brand-900 dark:bg-brand-800 dark:text-brand-100"

  defp heat_level_class(3), do: "bg-brand-500 text-white dark:bg-brand-600"
  defp heat_level_class(4), do: "bg-brand-700 text-white dark:bg-brand-400 dark:text-brand-900"

  defp day_title(date, count, metric) do
    day = Vutuv.ViewerClock.format(date, :date)

    case metric do
      "own" ->
        ngettext("%{count} post on %{day}", "%{count} posts on %{day}", count, day: day)

      _feed ->
        ngettext("%{count} entry on %{day}", "%{count} entries on %{day}", count, day: day)
    end
  end
end
