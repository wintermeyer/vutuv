defmodule Vutuv.Salary do
  @moduledoc """
  The shared salary model: whole-unit-integer amounts (never decimal — the
  codebase models money as integers, matching issue #928 as shipped), a small
  currency whitelist, a pay-period whitelist, cross-period normalisation, and
  the display helpers.

  ## Cross-period comparison

  To decide whether two pay figures overlap (the board filter #933 and the
  saved-search alerts #935), each is normalised to a **yearly equivalent** with
  fixed, documented factors. Currencies are **never converted** — a EUR figure
  and a USD figure simply do not salary-match (no FX guessing). The factors:

      hour  × 1720   # a German full-time year: ~40 h/week over ~43 worked weeks
      day   × 220    # worked days per year
      week  × 52
      month × 12
      year  × 1

  These are deliberately coarse and documented in `docs/architecture/jobs.md`;
  they exist to bucket figures for matching, not to compute anyone's real pay.
  """

  # `gettext/1` macro so the period nouns are picked up by `mix gettext.extract`
  # (a plain runtime `Gettext.gettext/2` call is never extracted).
  use Gettext, backend: VutuvWeb.Gettext

  @currencies ~w(EUR USD GBP CHF)
  @periods ~w(hour day week month year)

  @yearly_factors %{"hour" => 1720, "day" => 220, "week" => 52, "month" => 12, "year" => 1}

  @doc "The accepted salary currencies (ISO 4217)."
  def currencies, do: @currencies

  @doc "The accepted pay periods."
  def periods, do: @periods

  @doc "The currency symbol for display, falling back to the code (e.g. CHF)."
  def currency_symbol("EUR"), do: "€"
  def currency_symbol("USD"), do: "$"
  def currency_symbol("GBP"), do: "£"
  def currency_symbol(code) when is_binary(code), do: code

  @doc "The translated pay-period noun ('hour', 'day', …), for 'per <period>' UI."
  def period_label("hour"), do: gettext("hour")
  def period_label("day"), do: gettext("day")
  def period_label("week"), do: gettext("week")
  def period_label("month"), do: gettext("month")
  def period_label("year"), do: gettext("year")
  def period_label(other), do: other

  @doc "`{label, value}` currency pairs for a form select (symbol + code)."
  def currency_options, do: Enum.map(@currencies, &{"#{currency_symbol(&1)} #{&1}", &1})

  @doc "`{label, value}` period pairs for a form select."
  def period_options, do: Enum.map(@periods, &{period_label(&1), &1})

  @doc """
  A formatted "min–max symbol / period" pay line. `format` formats each amount
  (default the raw integer, for agent docs; the UI passes `&delimited_count/1`
  for locale-grouped digits). Equal min/max collapse to a single figure.
  """
  def range_label(min, max, currency, period, format \\ &Integer.to_string/1) do
    range = if min == max, do: format.(min), else: "#{format.(min)}–#{format.(max)}"
    "#{range} #{currency_symbol(currency)} / #{period_label(period)}"
  end

  @doc """
  The yearly-equivalent of `amount` paid per `period`, for cross-period
  comparison. `nil` amount → `nil`.
  """
  def yearly_equivalent(nil, _period), do: nil

  def yearly_equivalent(amount, period) when is_integer(amount),
    do: amount * Map.get(@yearly_factors, period, 1)
end
