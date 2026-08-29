defmodule Vutuv.ViewerClock do
  @moduledoc """
  The clock the page in front of *this* reader is written in: their time zone
  and their date shape (`Vutuv.DateRegions`), resolved once per request and
  read by every timestamp component (issue #1502).

  Distinct from `Vutuv.BerlinTime`, which is the **installation's** clock — the
  German calendar day the ad rotation books by and the nightly workers wake on.
  That one is the same for everybody; this one is not.

  ## Where the values come from

  `VutuvWeb.Plug.Locale` resolves them on every browser request and
  `VutuvWeb.LiveLocale` mirrors that in a LiveView process, exactly the way the
  Gettext locale is already carried, and for the same reason: a timestamp is
  rendered deep inside a component that has no business being handed the
  viewer, so the value lives in the **process dictionary** beside the locale.
  Both writers set every key on every request, so nothing survives from an
  earlier request on a re-used connection process; a process that never ran
  either (a worker, an `iex` session) reads the installation defaults.

  Resolution order:

  * **time zone** — the member's own `users.time_zone`, else the installation
    default (`Vutuv.Prefs`). A request carries no zone, so an anonymous
    visitor gets the installation's; `own_zone?/0` says which of the two
    happened, and `VutuvWeb.UI.local_time/1` leaves the client-side rewrite in
    place while it is false, so a visitor keeps seeing their browser's zone.
  * **date region** — the member's own `users.date_region`, else the guess
    from their browser's `Accept-Language`, else the installation default.
    The browser guess is in there so the millions of stamps an existing member
    reads stop being written US-style the moment they arrive, without waiting
    for them to find the setting.
  """

  alias Vutuv.DateRegions
  alias Vutuv.Prefs

  @region_key :vutuv_viewer_date_region
  @zone_key :vutuv_viewer_time_zone
  @own_zone_key :vutuv_viewer_own_time_zone

  @doc """
  Set this process's viewer clock. `zone` is the resolved zone (never nil) and
  `own_zone?` says whether it is the member's own choice rather than the
  installation default.
  """
  def put(region, zone, own_zone?)
      when is_binary(region) and is_binary(zone) and is_boolean(own_zone?) do
    Process.put(@region_key, region)
    Process.put(@zone_key, zone)
    Process.put(@own_zone_key, own_zone?)
    :ok
  end

  @doc """
  Resolve and set the clock for `user` (or `nil`), with `browser_region` as the
  middle layer — the `Accept-Language` guess a request or a mount session
  carries. The one place the resolution order above is written down.
  """
  def put_viewer(user, browser_region \\ nil) do
    own_zone = own_value(user, :time_zone)
    region = own_value(user, :date_region) || browser_region || Prefs.default(:date_region)

    put(region, own_zone || Prefs.default(:time_zone), own_zone != nil)
  end

  @doc "This viewer's date region key (`Vutuv.DateRegions`)."
  def region, do: Process.get(@region_key) || Prefs.default(:date_region)

  @doc "This viewer's IANA time zone."
  def zone, do: Process.get(@zone_key) || Prefs.default(:time_zone)

  @doc """
  Whether `zone/0` is the member's own setting rather than the installation
  default — the flag that decides if the server's text is final or the browser
  still gets to localize it.
  """
  def own_zone?, do: Process.get(@own_zone_key) == true

  @doc """
  A UTC instant as this viewer's wall-clock time, a `NaiveDateTime`. A naive
  argument is read as UTC, which is what every `inserted_at` in this app is.

  A zone the database cannot resolve (a value that outlived a tzdata release)
  falls back to UTC rather than raising: a stamp an hour off is a nuisance, a
  500 on the feed is not.
  """
  def naive(at) do
    case at |> as_utc() |> DateTime.shift_zone(zone()) do
      {:ok, shifted} -> DateTime.to_naive(shifted)
      {:error, _reason} -> at |> as_utc() |> DateTime.to_naive()
    end
  end

  @doc "The calendar date a UTC instant falls on for this viewer."
  def date(at), do: at |> naive() |> NaiveDateTime.to_date()

  @doc "Today, as this viewer's calendar day."
  def today, do: date(DateTime.utc_now())

  @doc """
  One of this viewer's calendar days as the pair of UTC naive instants that
  bound it — the inverse of `naive/1`, and the only place that conversion is
  written.

  Every `inserted_at` in the app is UTC naive, so anything that asks "what
  happened on my Tuesday" (the feed calendar's day window and its heatmap
  counts) has to turn the reader's day into that pair. `Vutuv.BerlinTime`'s
  `day_bounds_utc/1` is the same idea for the **installation's** clock; this is
  the per-reader twin.

  A day boundary never falls in a DST gap (transitions run at 02:00/03:00) and
  an ambiguous one still names the right day, so both odd shapes take the first
  offset rather than refusing the answer: an hour's skew at midnight is a
  nuisance, a 500 on the feed is not.
  """
  def day_window(%Date{} = date) do
    {edge(date, ~T[00:00:00]), edge(date, ~T[23:59:59])}
  end

  defp edge(%Date{} = date, %Time{} = time) do
    naive = NaiveDateTime.new!(date, time)

    case DateTime.from_naive(naive, zone()) do
      {:ok, at} -> to_utc_naive(at)
      {:ambiguous, first, _second} -> to_utc_naive(first)
      {:gap, just_before, _just_after} -> to_utc_naive(just_before)
      {:error, _reason} -> naive
    end
  end

  defp to_utc_naive(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  @doc """
  A UTC instant written in this viewer's shape. The styles are `:date`,
  `:short_date`, `:day_month`, `:time`, `:seconds`, `:datetime` (date and
  time), `:short_datetime` (the post-stamp form, comma-separated) and
  `:datetime_seconds`.

  A bare `%Date{}` names a calendar day rather than an instant — an issue date,
  a job's expiry, a birthday — so it is written in the viewer's shape but never
  shifted into their zone; only a date style may be asked of one.
  """
  def format(%Date{} = date, style) when style in [:date, :short_date, :day_month],
    do: Calendar.strftime(date, pattern(style))

  def format(at, style), do: at |> naive() |> Calendar.strftime(pattern(style))

  @doc "The `Calendar.strftime/2` pattern one style renders through."
  def pattern(style), do: pattern(region(), style)

  def pattern(region, :datetime),
    do: DateRegions.pattern(region, :date) <> " " <> DateRegions.pattern(region, :time)

  def pattern(region, :datetime_seconds),
    do: DateRegions.pattern(region, :date) <> " " <> DateRegions.pattern(region, :seconds)

  def pattern(region, :short_datetime),
    do: DateRegions.pattern(region, :short_date) <> ", " <> DateRegions.pattern(region, :time)

  def pattern(region, part), do: DateRegions.pattern(region, part)

  defp as_utc(%DateTime{} = at), do: at
  defp as_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp own_value(%{} = user, field) do
    case Map.get(user, field) do
      value when is_binary(value) and value != "" -> value
      _blank -> nil
    end
  end

  defp own_value(_user, _field), do: nil
end
