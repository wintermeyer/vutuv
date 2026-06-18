defmodule VutuvWeb.WorkExperienceHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  @doc """
  The `{label, value}` options for the start/end month selects on the
  work-experience form — defined once (the form needs the list twice) and
  translated, unlike the English literals it replaces.
  """
  def month_options do
    for n <- 1..12, do: {month_name(n), n}
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
    today = Date.utc_today()
    current_idx = today.year * 12 + (today.month - 1)

    measured = Enum.map(work_experiences, fn job -> {job, duration_months(job, current_idx)} end)
    max_months = [0 | Enum.map(measured, fn {_job, months} -> months || 0 end)] |> Enum.max()

    Enum.map(measured, fn {job, months} ->
      %{
        job: job,
        label: duration_label(months, label_style),
        length: duration_long_label(months),
        size: circle_rem(months, max_months)
      }
    end)
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

  embed_templates("../templates/work_experience/*")
end
