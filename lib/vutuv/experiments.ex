defmodule Vutuv.Experiments do
  @moduledoc """
  Split tests on public copy, and the counters that decide them.

  Today there is exactly one: `landing_headline`, the founder quote on the
  logged-out landing page. A visitor is assigned a variant at random on their
  first landing-page view, the choice is kept in the session they already have
  (so no new cookie is set and reloads keep showing the same headline), and
  three moments are counted per variant: the **view**, the **signup** (the
  sign-up form created an account) and the **confirmation** (that account
  entered its PIN and became a real member).

  Nothing per visitor is stored. `Vutuv.Experiments.Stat` holds one row per
  variant and Berlin calendar day with three integers in it, which is why this
  needs no consent banner and no privacy-page entry: there is no personal data
  to protect, and the session cookie carrying the choice is the strictly
  necessary one the sign-up form's CSRF token already requires.

  ## Reading the result

  Crawlers that ignore cookies get a fresh session per request and inflate
  `views` — but they inflate both variants alike, so the *conversion rates*
  are diluted while the *comparison* stays sound. That is also why
  `verdict/3` does not test the rates against each other: it tests how the
  signups themselves split between the two arms against the 50/50 the random
  assignment produces, which no amount of bot traffic can skew.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vutuv.BerlinTime
  alias Vutuv.Experiments.Stat
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  @landing_headline "landing_headline"

  # The two headlines under test (issue: "Begrüßung auf der Root-Seite").
  # "stube" is the warm invitation, "knapp" the dry two-sentence version;
  # VutuvWeb.PageHTML maps each key to its gettext string.
  @landing_variants ["stube", "knapp"]

  # Below this many signups in total, any split is noise. Reporting a winner
  # from the first handful of registrations is the classic way to ship the
  # worse headline with great confidence.
  @min_signups 30

  @doc "The key of the landing-page headline experiment."
  def landing_headline, do: @landing_headline

  @doc "Every variant key of the landing-page headline experiment."
  def landing_variants, do: @landing_variants

  @doc """
  The variant served when the experiment is switched off (or the session
  carries something unknown). Also the one an installation that never runs
  the test sees.
  """
  def default_landing_variant, do: hd(@landing_variants)

  @doc """
  Whether the split test runs at all.

  Off means every visitor sees `default_landing_variant/0` and nothing is
  counted — the setting for an installation that has no interest in our
  marketing copy. See `:landing_headline_experiment` in `config/config.exs`
  (env override `LANDING_HEADLINE_EXPERIMENT`).
  """
  def enabled?, do: Application.get_env(:vutuv, :landing_headline_experiment, false)

  @doc "A random variant, or the default while the experiment is off."
  def pick_landing_variant do
    if enabled?(), do: Enum.random(@landing_variants), else: default_landing_variant()
  end

  @doc "Whether `variant` is one this experiment serves."
  def landing_variant?(variant), do: variant in @landing_variants

  @doc """
  Adds one to `counter` for `variant` on today's Berlin day.

  A no-op for an unknown variant or while the experiment is off, so every
  call site can stay a plain one-liner. The write is a single upsert against
  the `[experiment, variant, day]` unique index, so concurrent requests
  increment rather than race.
  """
  def record(variant, counter)
      when counter in [:views, :signups, :confirmations] do
    if enabled?() and landing_variant?(variant) do
      bump(@landing_headline, variant, counter)
    else
      :ok
    end
  end

  # A counter is never worth a 500 on the most-visited public page there is.
  # The landing page does almost no other database work, so this write is the
  # one thing on it that can fail, and a lost tally is a rounding error next to
  # a start page that does not render — so anything the write raises is logged
  # and swallowed. (The table's own arrival is safe by construction: the
  # blue/green deploy migrates while the previous release, which never touches
  # it, is still serving.)
  defp bump(experiment, variant, counter) do
    do_bump(experiment, variant, counter)
  rescue
    error ->
      Logger.warning(
        "experiment counter #{experiment}/#{variant}/#{counter} failed: " <>
          Exception.message(error)
      )

      :ok
  end

  defp do_bump(experiment, variant, counter) do
    # The timestamps are UTC like every other table's; only `day` is the
    # Berlin calendar day, so a report groups by the German day.
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    Repo.insert_all(
      Stat,
      [
        [
          id: UUIDv7.generate(),
          experiment: experiment,
          variant: variant,
          day: BerlinTime.today(),
          views: if(counter == :views, do: 1, else: 0),
          signups: if(counter == :signups, do: 1, else: 0),
          confirmations: if(counter == :confirmations, do: 1, else: 0),
          inserted_at: now,
          updated_at: now
        ]
      ],
      on_conflict: [inc: [{counter, 1}], set: [updated_at: now]],
      conflict_target: [:experiment, :variant, :day]
    )

    :ok
  end

  @doc """
  The whole experiment as the admin page renders it.

  Returns the per-variant totals (each with its conversion rates), the
  per-day rows newest first, and a verdict for both the signup and the
  confirmation split.
  """
  def report(experiment \\ @landing_headline) do
    rows =
      Stat
      |> where([s], s.experiment == ^experiment)
      |> order_by([s], desc: s.day, asc: s.variant)
      |> Repo.all()

    totals = Enum.map(@landing_variants, &totals_for(rows, &1))

    %{
      totals: totals,
      days: by_day(rows),
      signup_verdict: verdict(totals, :signups),
      confirmation_verdict: verdict(totals, :confirmations)
    }
  end

  defp totals_for(rows, variant) do
    rows = Enum.filter(rows, &(&1.variant == variant))
    views = sum(rows, :views)
    signups = sum(rows, :signups)
    confirmations = sum(rows, :confirmations)

    %{
      variant: variant,
      views: views,
      signups: signups,
      confirmations: confirmations,
      signup_rate: rate(signups, views),
      confirmation_rate: rate(confirmations, views)
    }
  end

  defp sum(rows, field), do: Enum.reduce(rows, 0, &(Map.fetch!(&1, field) + &2))

  # nil rather than 0.0 for "no views yet", so the page can print a dash
  # instead of a 0% that reads like a measured failure.
  defp rate(_count, 0), do: nil
  defp rate(count, views), do: count / views

  defp by_day(rows) do
    rows
    |> Enum.group_by(& &1.day)
    |> Enum.sort_by(fn {day, _rows} -> day end, {:desc, Date})
    |> Enum.map(fn {day, day_rows} ->
      %{day: day, variants: Enum.map(@landing_variants, &totals_for(day_rows, &1))}
    end)
  end

  @doc """
  Which variant is ahead on `metric`, and how sure we are.

  The test: under a fair coin the winning arm's share of the outcomes is
  Binomial(n, 0.5), so a split far enough from 50/50 is the signal. Uses the
  normal approximation with a continuity correction (exact enough from the
  ~30 outcomes `@min_signups` demands, and it keeps the maths readable).

  Returns `{:too_early, n}`, `{:tie, n}`, `{:inconclusive, winner, p}` or
  `{:significant, winner, p}` — significant meaning p < 0.05.
  """
  def verdict(totals, metric) when metric in [:signups, :confirmations] do
    counts = Enum.map(totals, &{&1.variant, Map.fetch!(&1, metric)})
    n = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {winner, best} = Enum.max_by(counts, &elem(&1, 1))

    cond do
      n < @min_signups -> {:too_early, n}
      best * 2 == n -> {:tie, n}
      true -> classify(winner, p_value(best, n))
    end
  end

  defp classify(winner, p) when p < 0.05, do: {:significant, winner, p}
  defp classify(winner, p), do: {:inconclusive, winner, p}

  @doc "Two-sided p-value for `hits` out of `n` outcomes against a 50/50 split."
  def p_value(hits, n) when n > 0 do
    z = (abs(hits - n / 2) - 0.5) / (:math.sqrt(n) / 2)

    if z <= 0, do: 1.0, else: min(1.0, 2 * (1 - normal_cdf(z)))
  end

  defp normal_cdf(z), do: 0.5 * (1 + erf(z / :math.sqrt(2)))

  # Abramowitz & Stegun 7.1.26 (max error 1.5e-7) — Erlang's :math has no erf,
  # and one approximation is cheaper than a dependency for a single admin page.
  defp erf(x) when x < 0, do: -erf(-x)

  defp erf(x) do
    t = 1 / (1 + 0.3275911 * x)

    poly =
      t *
        (0.254829592 +
           t *
             (-0.284496736 +
                t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))

    1 - poly * :math.exp(-x * x)
  end

  @doc "The smallest number of outcomes before `verdict/2` says anything."
  def min_signups, do: @min_signups
end
