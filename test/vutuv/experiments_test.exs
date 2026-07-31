defmodule Vutuv.ExperimentsTest do
  @moduledoc """
  `async: false` on purpose: these tests upsert the same `experiment_stats`
  rows (the fixed production variants "stube"/"knapp" on today's Berlin day)
  as `VutuvWeb.LandingExperimentTest`, and two async modules incrementing the
  same unique-key rows in opposite orders deadlock (40P01) — the lost
  increment then fails the counting assertions. The variant names are
  production data, not test literals, so they cannot be uniquified per module.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.BerlinTime
  alias Vutuv.Experiments

  @variant_a "stube"
  @variant_b "knapp"

  describe "landing variants" do
    test "there are exactly two, and the default is one of them" do
      assert length(Experiments.landing_variants()) == 2
      assert Experiments.default_landing_variant() in Experiments.landing_variants()
    end

    test "pick_landing_variant/0 only ever returns a known variant" do
      picks = for _ <- 1..50, do: Experiments.pick_landing_variant()

      assert Enum.all?(picks, &Experiments.landing_variant?/1)
    end

    test "landing_variant?/1 rejects anything else" do
      refute Experiments.landing_variant?("smuggled")
      refute Experiments.landing_variant?(nil)
    end
  end

  describe "record/2" do
    test "counts each metric separately, on today's Berlin day" do
      Experiments.record(@variant_a, :views)
      Experiments.record(@variant_a, :views)
      Experiments.record(@variant_a, :signups)
      Experiments.record(@variant_a, :confirmations)

      assert %{totals: totals, days: [day]} = Experiments.report()
      assert %{views: 2, signups: 1, confirmations: 1} = variant(totals, @variant_a)
      assert day.day == BerlinTime.today()
    end

    test "keeps the two variants apart" do
      Experiments.record(@variant_a, :views)
      Experiments.record(@variant_b, :views)
      Experiments.record(@variant_b, :signups)

      %{totals: totals} = Experiments.report()

      assert %{views: 1, signups: 0} = variant(totals, @variant_a)
      assert %{views: 1, signups: 1} = variant(totals, @variant_b)
    end

    test "ignores an unknown variant instead of minting a row for it" do
      assert :ok = Experiments.record("smuggled", :views)

      %{totals: totals} = Experiments.report()

      assert Enum.map(totals, & &1.variant) == Experiments.landing_variants()
      assert Enum.all?(totals, &(&1.views == 0))
    end

    test "reports every variant even before anything is counted" do
      %{totals: totals, days: days} = Experiments.report()

      assert Enum.map(totals, & &1.variant) == Experiments.landing_variants()
      assert days == []
      # No views yet is a dash on the page, not a measured 0%.
      assert Enum.all?(totals, &is_nil(&1.signup_rate))
    end
  end

  describe "report/1 rates" do
    test "divides signups and confirmations by the views" do
      for _ <- 1..4, do: Experiments.record(@variant_a, :views)
      Experiments.record(@variant_a, :signups)

      %{totals: totals} = Experiments.report()

      assert variant(totals, @variant_a).signup_rate == 0.25
      assert variant(totals, @variant_a).confirmation_rate == 0.0
    end
  end

  describe "verdict/2" do
    test "says too_early below the minimum number of outcomes" do
      totals = totals(signups: {5, 1})

      assert {:too_early, 6} = Experiments.verdict(totals, :signups)
    end

    test "says tie on an even split" do
      totals = totals(signups: {40, 40})

      assert {:tie, 80} = Experiments.verdict(totals, :signups)
    end

    test "names a leader but stays inconclusive on a narrow lead" do
      totals = totals(signups: {55, 45})

      assert {:inconclusive, @variant_a, p} = Experiments.verdict(totals, :signups)
      assert p > 0.05
    end

    test "calls a wide lead significant" do
      totals = totals(signups: {70, 30})

      assert {:significant, @variant_a, p} = Experiments.verdict(totals, :signups)
      assert p < 0.05
    end

    test "judges the confirmation split on its own numbers" do
      totals = totals(signups: {70, 30}, confirmations: {40, 40})

      assert {:significant, @variant_a, _} = Experiments.verdict(totals, :signups)
      assert {:tie, 80} = Experiments.verdict(totals, :confirmations)
    end
  end

  describe "p_value/2" do
    test "an even split is as unremarkable as it gets" do
      assert Experiments.p_value(50, 100) == 1.0
    end

    test "shrinks as the split widens" do
      assert Experiments.p_value(60, 100) > Experiments.p_value(70, 100)
    end

    test "approximates the textbook two-sided binomial figures" do
      # 60/100 against a fair coin is p ~ 0.0569 (exact test: 0.0569).
      assert_in_delta Experiments.p_value(60, 100), 0.0569, 0.005
      # 70/100 is p ~ 0.0000785.
      assert_in_delta Experiments.p_value(70, 100), 0.0000785, 0.0001
    end
  end

  defp variant(totals, variant), do: Enum.find(totals, &(&1.variant == variant))

  # Builds the totals shape `verdict/2` reads, without touching the database.
  defp totals(counts) do
    {a_signups, b_signups} = Keyword.get(counts, :signups, {0, 0})
    {a_confirmed, b_confirmed} = Keyword.get(counts, :confirmations, {0, 0})

    [
      %{variant: @variant_a, signups: a_signups, confirmations: a_confirmed},
      %{variant: @variant_b, signups: b_signups, confirmations: b_confirmed}
    ]
  end
end
