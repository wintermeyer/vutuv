defmodule VutuvWeb.Admin.ExperimentHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias VutuvWeb.PageHTML

  embed_templates("../../templates/admin/experiment/*")

  @doc "The human name of a variant, so the table is not a column of slugs."
  def variant_label("knapp"), do: gettext("Short version")
  def variant_label(_stube), do: gettext("Invitation")

  @doc "The headline this variant actually shows, in the reading admin's language."
  def variant_quote(variant), do: PageHTML.founder_quote(variant)

  @doc """
  A share as a percentage, or a dash while there is nothing to divide by.

  A rate of 0 % on a variant nobody has seen yet would read as a measured
  failure, which is why `Vutuv.Experiments` hands back nil for that case.
  """
  def percent(nil), do: "–"

  def percent(rate) when is_float(rate) do
    (rate * 100)
    |> :erlang.float_to_binary(decimals: 2)
    |> localize_decimal()
    |> Kernel.<>(" %")
  end

  @doc """
  The verdict as one sentence an admin can act on.

  Deliberately plain language over statistical vocabulary: the number that
  matters is how often a split this lopsided would turn up by pure chance.
  """
  def verdict_text({:too_early, count}, min) do
    gettext(
      "Too early to say: %{count} of at least %{min} outcomes. Anything read out of the numbers below now is noise.",
      count: delimited_count(count),
      min: delimited_count(min)
    )
  end

  def verdict_text({:tie, count}, _min) do
    gettext("Dead even across %{count} outcomes. Neither headline is pulling ahead.",
      count: delimited_count(count)
    )
  end

  def verdict_text({:inconclusive, winner, p}, _min) do
    gettext(
      "%{variant} is ahead, but a lead this size turns up by chance %{p} of the time. Keep the test running.",
      variant: variant_label(winner),
      p: probability(p)
    )
  end

  def verdict_text({:significant, winner, p}, _min) do
    gettext(
      "%{variant} wins. A lead this size turns up by chance only %{p} of the time, so the difference is real.",
      variant: variant_label(winner),
      p: probability(p)
    )
  end

  @doc "Whether the verdict deserves the page's attention treatment."
  def verdict_decided?({:significant, _winner, _p}), do: true
  def verdict_decided?(_verdict), do: false

  # A p-value as a percentage the sentence can carry: "0,01 %" rather than
  # "p = 1.0e-4". Anything under a hundredth of a percent is just "less than".
  defp probability(p) when p < 0.0001, do: "< " <> percent(0.0001)
  defp probability(p), do: percent(p)

  defp localize_decimal(value) do
    if Gettext.get_locale(VutuvWeb.Gettext) == "de",
      do: String.replace(value, ".", ","),
      else: value
  end
end
