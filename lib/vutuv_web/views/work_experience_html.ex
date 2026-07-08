defmodule VutuvWeb.WorkExperienceHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.Profiles.WorkExperience

  @doc """
  The `{label, value}` options for the start/end month selects on the
  work-experience form — defined once (the form needs the list twice) and
  translated, unlike the English literals it replaces.
  """
  def month_options do
    for n <- 1..12, do: {month_name(n), n}
  end

  @doc """
  The category name of a single entry (issue #840), for the form's picker
  and the entry show page.
  """
  def kind_name("employment"), do: gettext("Employment")
  def kind_name("self_employed"), do: gettext("Freelance / Self-employed")
  def kind_name("internship"), do: gettext("Internship")
  def kind_name("volunteer"), do: gettext("Volunteer position")
  def kind_name("other"), do: gettext("Other activities")

  @doc "A category's group heading on the list renderings."
  def kind_label("employment"), do: gettext("Professional Experience")
  def kind_label("self_employed"), do: gettext("Freelance / Self-employed")
  def kind_label("internship"), do: gettext("Internships")
  def kind_label("volunteer"), do: gettext("Volunteering")
  def kind_label("other"), do: gettext("Other activities")

  @doc "The `{label, value}` options for the form's category select."
  def kind_options do
    for kind <- WorkExperience.kinds(), do: {kind_name(kind), kind}
  end

  @doc """
  `circle_durations/2` clustered by employer (LinkedIn-style) and split into the
  CV categories. Returns `{kind, [block]}` pairs in display order (empty
  categories dropped).

  Within a category, a run of **consecutive** roles that share an organization
  collapses into one company block. "Consecutive" is the point after the CV
  categories have split the list: volunteer or freelance rows must not break an
  employment run at the same employer, but a different employment job between
  two stints still keeps them as two blocks. Roles without an organization never
  cluster.

  A block is a map:

    * `:kind` — the CV category (all roles in a block share it)
    * `:organization` — the employer name
    * `:multi?` — `true` once the block holds more than one role
    * `:roles` — the member's `circle_durations/2` circles for the block, newest
      first (each still carries its own `:dates` label and readable `:length`)
    * `:span` — `%{label:, detail:}` from the earliest start to the latest end
      across the whole block (a single-role block reuses the role's own dates)
    * `:length` — the readable total tenure across the block, e.g. `"9 years"`
    * `:label` — the compact centre text for the block's duration circle (`"9y"`)
    * `:size` — the block circle's diameter in rem

  The block circles are ranked over the **block totals** (a company's whole
  tenure), so the longest *employer*, not the longest single role, fills the
  largest circle; and short internships still can't inflate past a decade-long
  job because the whole list is measured before any grouping.

  `limit` caps the number of **displayed** roles (nil = no cap, the full CV page;
  the profile preview passes `profile_preview_limit/0`). Always pass the member's
  **whole** work history and let `limit` do the trimming — the block aggregates
  (tenure, span, circle) are built from every role at an employer *before* the
  cut, so a truncated company still reports its true total (a member with 3 roles
  over 9 years at one employer keeps "9 years" even when the cut shows only 2).
  """
  def grouped_clusters(work_experiences, label_style \\ :years, limit \\ nil) do
    indexed_circles =
      work_experiences
      |> circle_durations(label_style)
      |> Enum.with_index()

    indexed_blocks =
      indexed_circles
      |> grouped_indexed_circles()
      |> Enum.flat_map(&chunk_indexed_circles/1)

    totals = Enum.map(indexed_blocks, fn {_index, roles} -> block_months(roles) end)
    max_months = [0 | Enum.reject(totals, &is_nil/1)] |> Enum.max()

    built =
      indexed_blocks
      |> Enum.zip(totals)
      |> Enum.map(fn {{index, roles}, months} ->
        {index, build_block(roles, months, max_months, label_style)}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> take_roles(limit)

    groups = Enum.group_by(built, & &1.kind)
    for kind <- WorkExperience.kinds(), kind_blocks = groups[kind], do: {kind, kind_blocks}
  end

  @profile_preview_roles 10

  @doc """
  How many roles the profile Experience card previews before truncating with an
  "Alle anzeigen" link; the section page (`/:slug/work_experiences`) shows all.
  Shared by the preview call and the `manage_footer` "View All" threshold so the
  two can never disagree.
  """
  def profile_preview_limit, do: @profile_preview_roles

  # Cap the number of *displayed* roles at `limit` (nil = no cap), truncating the
  # block that straddles the cap and dropping the blocks past it. A truncated
  # block keeps its full aggregates — those are built from every role at the
  # employer before this cut, so a company's tenure/circle stays right even when
  # only some of its roles are shown.
  defp take_roles(blocks, nil), do: blocks

  defp take_roles(blocks, limit) do
    {kept, _left} =
      Enum.flat_map_reduce(blocks, limit, fn block, left ->
        cond do
          left <= 0 -> {[], 0}
          length(block.roles) <= left -> {[block], left - length(block.roles)}
          true -> {[%{block | roles: Enum.take(block.roles, left)}], 0}
        end
      end)

    kept
  end

  defp grouped_indexed_circles(indexed_circles) do
    groups = Enum.group_by(indexed_circles, fn {circle, _index} -> circle.job.kind end)

    for kind <- WorkExperience.kinds(), entries = groups[kind], do: entries
  end

  defp chunk_indexed_circles(indexed_circles) do
    indexed_circles
    |> Enum.chunk_by(fn {circle, index} -> chunk_key(circle.job, index) end)
    |> Enum.map(fn chunk ->
      {chunk |> Enum.map(&elem(&1, 1)) |> Enum.min(), Enum.map(chunk, &elem(&1, 0))}
    end)
  end

  # Adjacent circles inside the same CV category cluster only when they share a
  # normalised organization. A blank organization gets a per-row unique key so
  # undated / employer-less roles never merge into one another.
  defp chunk_key(job, index) do
    case normalize_org(job.organization) do
      "" -> {:solo, index}
      org -> org
    end
  end

  defp normalize_org(nil), do: ""
  defp normalize_org(org), do: org |> String.trim() |> String.downcase()

  # Total tenure across a block: the span from the earliest start to the latest
  # end (an ongoing role runs the block to today). nil when nothing is dated.
  defp block_months(circles) do
    current_idx = current_month_index()

    points =
      Enum.map(circles, fn %{job: job} ->
        start = start_index(job)
        {start, end_index(job) || if(not is_nil(start), do: current_idx)}
      end)

    starts = points |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
    finishes = points |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    if starts == [] or finishes == [],
      do: nil,
      else: max(Enum.max(finishes) - Enum.min(starts), 0)
  end

  defp build_block(circles, months, max_months, label_style) do
    newest = hd(circles).job
    oldest = List.last(circles).job
    multi? = match?([_, _ | _], circles)

    span =
      if multi? do
        duration_with_detail(
          oldest.start_month,
          oldest.start_year,
          newest.end_month,
          newest.end_year
        )
      else
        hd(circles).dates
      end

    %{
      kind: newest.kind,
      organization: newest.organization,
      multi?: multi?,
      roles: circles,
      span: span,
      length: duration_long_label(months),
      label: duration_label(months, label_style),
      size: circle_rem(months, max_months)
    }
  end

  @doc """
  Category headings appear only once a non-employment entry exists — the
  common jobs-only member keeps the familiar single unlabeled timeline.
  """
  def show_kind_headings?(work_experiences) do
    Enum.any?(work_experiences, &(&1.kind != "employment"))
  end

  @doc """
  Renders a role's date range. `order` controls month/year ordering within each
  endpoint: `:month_first` (default) yields `3/2018`, `:year_first` yields
  `2018/3`.
  """
  def format_duration(start_month, start_year, end_month, end_year, order \\ :month_first) do
    case {start_month, start_year, end_month, end_year} do
      {nil, nil, end_month, end_year} ->
        display_date(end_month, end_year, order)

      _ ->
        [
          display_date(start_month, start_year, order),
          " - ",
          display_date(end_month, end_year, order)
        ]
    end
  end

  defp display_date(month, year, order) do
    case {month, year} do
      {nil, year} when is_integer(year) ->
        Integer.to_string(year)

      {month, year} when is_integer(month) and is_integer(year) ->
        case order do
          :year_first -> [Integer.to_string(year), "/", Integer.to_string(month)]
          _ -> [Integer.to_string(month), "/", Integer.to_string(year)]
        end

      _ ->
        gettext("Present")
    end
  end

  @doc """
  Date-range display for the profile experience rail. Months never show in the
  label; they ride along in `detail` for a hover tooltip when there are months
  worth revealing.

    * same start and end year -> just that year (`2003`)
    * different years -> the year span (`2005 - 2017`)
    * open-ended -> `2005 - Present`
    * end-only / undated -> whatever `format_duration/5` yields, no tooltip

  Returns `%{label: iodata, detail: binary | nil}`.
  """
  def duration_with_detail(start_month, start_year, end_month, end_year) do
    full = format_duration(start_month, start_year, end_month, end_year, :year_first)

    cond do
      same_year?(start_year, end_year) ->
        %{
          label: Integer.to_string(start_year),
          detail: month_detail(start_month, end_month, full)
        }

      multi_year?(start_year, end_year) ->
        %{label: years_span(start_year, end_year), detail: IO.iodata_to_binary(full)}

      true ->
        %{label: full, detail: nil}
    end
  end

  defp same_year?(start_year, end_year) when is_integer(start_year) and is_integer(end_year),
    do: start_year == end_year

  defp same_year?(_start_year, _end_year), do: false

  defp multi_year?(start_year, end_year) when is_integer(start_year) and is_integer(end_year),
    do: start_year != end_year

  defp multi_year?(start_year, nil) when is_integer(start_year), do: true
  defp multi_year?(_start_year, _end_year), do: false

  # The exact month/year range, surfaced as a tooltip only when at least one
  # month is known (a year-only range adds nothing the label doesn't show).
  defp month_detail(start_month, end_month, full)
       when is_integer(start_month) or is_integer(end_month),
       do: IO.iodata_to_binary(full)

  defp month_detail(_start_month, _end_month, _full), do: nil

  defp years_span(start_year, nil), do: [Integer.to_string(start_year), " - ", gettext("Present")]

  defp years_span(start_year, end_year),
    do: [Integer.to_string(start_year), " - ", Integer.to_string(end_year)]

  # Month axis index (year * 12 + month-1); nil when there is no year to anchor.
  # Start defaults to January, end to December of the given year.
  defp start_index(%{start_year: year, start_month: month}) when is_integer(year),
    do: year * 12 + ((month || 1) - 1)

  defp start_index(_job), do: nil

  defp end_index(%{end_year: year, end_month: month}) when is_integer(year),
    do: year * 12 + ((month || 12) - 1)

  defp end_index(_job), do: nil

  @doc """
  Per-role circle sizing for the "duration circles" layout. Each role gets a
  circle whose diameter grows with the number of years it lasted (linear in
  years, scaled so the longest role fills the largest circle) plus a short
  duration label for its centre. `label_style` picks the centre text:

    * `:years` (default) — `12` for years, `<1` for under a year, `""` undated
    * `:compact` — `5y` for whole years, `3m` for sub-year months

  Roles with no start date can't be measured and fall back to the smallest
  circle with a blank label. Returned in input order.
  """
  def circle_durations(work_experiences, label_style \\ :years) do
    current_idx = current_month_index()

    measured = Enum.map(work_experiences, fn job -> {job, duration_months(job, current_idx)} end)
    max_months = [0 | Enum.map(measured, fn {_job, months} -> months || 0 end)] |> Enum.max()

    Enum.map(measured, fn {job, months} ->
      %{
        job: job,
        months: months,
        label: duration_label(months, label_style),
        length: duration_long_label(months),
        size: circle_rem(months, max_months),
        dates: duration_with_detail(job.start_month, job.start_year, job.end_month, job.end_year)
      }
    end)
  end

  # Month axis index for "now" (year * 12 + month-1), the anchor an ongoing role
  # or an open-ended block runs to.
  defp current_month_index do
    today = Date.utc_today()
    today.year * 12 + (today.month - 1)
  end

  # Readable length for inline prose, e.g. "12 years" / "4 months"; nil when the
  # role has no start date to measure from.
  defp duration_long_label(nil), do: nil

  defp duration_long_label(months) when months < 12,
    do: ngettext("%{count} month", "%{count} months", max(months, 1))

  defp duration_long_label(months),
    do: ngettext("%{count} year", "%{count} years", round(months / 12))

  defp duration_months(job, current_idx) do
    start = start_index(job)
    finish = end_index(job) || if(not is_nil(start), do: current_idx)

    if is_nil(start) or is_nil(finish), do: nil, else: max(finish - start, 0)
  end

  defp duration_label(nil, _style), do: ""
  defp duration_label(months, :compact) when months < 12, do: "#{max(months, 1)}m"
  defp duration_label(months, :compact), do: "#{round(months / 12)}y"
  defp duration_label(months, _years) when months < 12, do: "<1"
  defp duration_label(months, _years), do: Integer.to_string(round(months / 12))

  # Diameter in rem. sqrt keeps the longest role dominant while spreading the
  # short roles far enough apart to rank them by eye (a linear map squashed a
  # four-month role and a two-year role to nearly the same size). Clamped to a
  # legible minimum so the centre label still fits.
  defp circle_rem(nil, _max_months), do: 1.6
  defp circle_rem(_months, max_months) when max_months <= 0, do: 1.6
  defp circle_rem(months, max_months), do: 1.6 + :math.sqrt(months / max_months) * (4.0 - 1.6)

  @doc """
  The member's pinned profile job title (issue #833), found in the already-
  loaded list, or nil when they use the automatic heuristic. `id` is a
  member's `users.profile_work_experience_id`.
  """
  def pinned_job(_work_experiences, nil), do: nil
  def pinned_job(work_experiences, id), do: Enum.find(work_experiences, &(&1.id == id))

  @doc """
  The star that marks (and toggles) which work experience supplies the profile
  job title on the management list (issue #833): solid when this role is the
  pinned one, outline as the "pin this one instead" affordance otherwise. One
  path renders both, colour and fill come from the caller's classes.
  """
  attr(:filled, :boolean, default: false)
  attr(:class, :string, default: "h-4 w-4")

  def pin_star(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 20 20"
      fill={if(@filled, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width={if(@filled, do: "0", else: "1.5")}
      aria-hidden="true"
    >
      <path
        stroke-linejoin="round"
        d="M10 1.75l2.6 5.27 5.82.846-4.21 4.104.994 5.796L10 15.1l-5.204 2.736.994-5.796L1.58 7.866l5.82-.846L10 1.75z"
      />
    </svg>
    """
  end

  @doc """
  One timeline block from `grouped_clusters/2`, shared by the
  section page (`work_experience/card_list`) and the profile Experience card so
  the clustering can never drift between them.

  A single-role block reads like a classic entry: the title, the organization
  and the duration inline, one duration circle. A multi-role block reads like
  LinkedIn's grouped employer: the organization as a header with the total
  tenure and one circle, the roles nested beneath on the same rail, each with
  its own date range, duration and (owner only) pin + edit/delete controls.

    * `as_owner?` — render the owner's pin + edit/delete controls and drop the
      duration circle (the /settings editor is a working list). Visitors and the
      profile card pass `false`, so they get the showcase with circles.
    * `show_description?` — render each role's description (the section page
      does; the profile preview keeps it tight and does not).
  """
  attr(:block, :map, required: true)
  attr(:user, :any, required: true)
  attr(:as_owner?, :boolean, default: false)
  attr(:show_description?, :boolean, default: false)
  attr(:profile_work_experience_id, :any, default: nil)

  def experience_block(assigns) do
    ~H"""
    <div class={[
      "grid items-start gap-3",
      if(@as_owner?, do: "grid-cols-[6.5rem_1fr]", else: "grid-cols-[6.5rem_1fr_4rem]")
    ]}>
      <div
        class="pt-0.5 text-right text-xs font-semibold leading-tight tabular-nums text-slate-600 dark:text-slate-400"
        title={@block.span.detail}
      >
        {@block.span.label}
      </div>

      <div>
        <%= if @block.multi? do %>
          <%!-- Git-graph layout: the employer is a node on the
          trunk (the outer rail, continuous down the whole timeline); its roles
          run on a branch — a second rail offset to the right — that diverges
          from the trunk with a slanted connector at the top and merges back with
          one at the bottom, so the grouping reads like a feature branch. The
          trunk carries the brand employer node, the branch the quieter roles. --%>
          <div class="relative border-l border-slate-200 pb-4 dark:border-slate-700">
            <div class="relative pb-4 pl-5">
              <span class="absolute -left-[0.3125rem] top-1.5 h-2.5 w-2.5 rounded-full bg-brand-600 ring-4 ring-white dark:ring-slate-900"></span>
              <p class="mb-0.5 font-semibold text-slate-900 dark:text-white">
                {@block.organization}
              </p>
              <p :if={@block.length} class="mb-0 text-sm text-slate-600 dark:text-slate-400">
                {@block.length}
              </p>
            </div>
            <div class="relative ml-5 border-l border-slate-200 dark:border-slate-700">
              <%!-- Slanted diverge (top) and merge (bottom) connectors bridging
              the branch rail back to the trunk 20px to its left. --%>
              <svg
                class="pointer-events-none absolute -left-5 -top-4 h-4 w-5 text-slate-200 dark:text-slate-700"
                viewBox="0 0 20 16"
                fill="none"
                aria-hidden="true"
              >
                <path d="M0 0 C 0 9, 20 7, 20 16" stroke="currentColor" stroke-width="1" />
              </svg>
              <svg
                class="pointer-events-none absolute -left-5 -bottom-4 h-4 w-5 text-slate-200 dark:text-slate-700"
                viewBox="0 0 20 16"
                fill="none"
                aria-hidden="true"
              >
                <path d="M20 0 C 20 9, 0 7, 0 16" stroke="currentColor" stroke-width="1" />
              </svg>
              <div :for={role <- @block.roles} class="relative pb-3 pl-5 last:pb-2">
                <span class="absolute -left-[0.25rem] top-1.5 h-2 w-2 rounded-full bg-slate-300 ring-4 ring-white dark:bg-slate-600 dark:ring-slate-900"></span>
                <.link
                  href={~p"/#{@user}/work_experiences/#{role.job}"}
                  class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white"
                >
                  {role.job.title}
                </.link>
                <p class="text-sm text-slate-600 dark:text-slate-400">
                  {role.dates.label}<%= if role.length do %> · {role.length}<% end %>
                </p>
                <p
                  :if={@show_description? and role.job.description}
                  class="mt-1 text-sm text-slate-600 dark:text-slate-400"
                >
                  {role.job.description}
                </p>
                <.role_owner_controls
                  :if={@as_owner?}
                  user={@user}
                  job={role.job}
                  profile_work_experience_id={@profile_work_experience_id}
                />
              </div>
            </div>
          </div>
        <% else %>
          <% role = hd(@block.roles) %>
          <div class="relative border-l border-slate-200 pb-6 pl-5 dark:border-slate-700">
            <span class="absolute -left-[0.3125rem] top-1.5 h-2.5 w-2.5 rounded-full bg-brand-600 ring-4 ring-white dark:ring-slate-900"></span>
            <.link
              href={~p"/#{@user}/work_experiences/#{role.job}"}
              class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white"
            >
              {role.job.title}
            </.link>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {role.job.organization}<%= if role.length do %> · {role.length}<% end %>
            </p>
            <p
              :if={@show_description? and role.job.description}
              class="mt-1 text-sm text-slate-600 dark:text-slate-400"
            >
              {role.job.description}
            </p>
            <.role_owner_controls
              :if={@as_owner?}
              user={@user}
              job={role.job}
              profile_work_experience_id={@profile_work_experience_id}
            />
          </div>
        <% end %>
      </div>

      <div
        :if={!@as_owner?}
        class="flex shrink-0 items-center justify-center justify-self-center rounded-full bg-brand-600 font-semibold leading-none tabular-nums text-white"
        style={"width: #{@block.size}rem; height: #{@block.size}rem"}
        title={
          if(@block.multi?,
            do: gettext("Total time at this employer"),
            else: gettext("Time in this role")
          )
        }
      >
        <span class="text-[11px]">{@block.label}</span>
      </div>
    </div>
    """
  end

  @doc """
  The owner's pin (issue #833) + Edit/Delete controls under one role, shared by
  the single-role and nested-role branches of `experience_block/1`.
  """
  attr(:user, :any, required: true)
  attr(:job, :any, required: true)
  attr(:profile_work_experience_id, :any, default: nil)

  def role_owner_controls(assigns) do
    ~H"""
    <div class="mt-2">
      <span
        :if={@profile_work_experience_id == @job.id}
        class="inline-flex items-center gap-1 text-xs font-semibold text-brand-700 dark:text-brand-400"
      >
        <.pin_star filled class="h-4 w-4" />
        {gettext("Shown at the top of your profile")}
      </span>
      <.link
        :if={@profile_work_experience_id != @job.id}
        href={~p"/settings/work_experiences/#{@job}/pin"}
        method="put"
        class="inline-flex items-center gap-1 rounded-full border border-brand-600 px-3 py-1 text-xs font-semibold text-brand-600 hover:bg-brand-50 dark:border-brand-400 dark:text-brand-400 dark:hover:bg-brand-900/40"
      >
        <.pin_star class="h-4 w-4" />
        {gettext("Show at top of profile")}
      </.link>
    </div>
    <.row_actions
      align={:start}
      class="mt-2"
      edit_to={~p"/settings/work_experiences/#{@job}/edit"}
      delete_to={~p"/settings/work_experiences/#{@job}"}
    />
    """
  end

  embed_templates("../templates/work_experience/*")
end
