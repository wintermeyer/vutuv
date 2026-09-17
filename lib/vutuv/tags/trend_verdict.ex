defmodule Vutuv.Tags.TrendVerdict do
  @moduledoc """
  What the trending pass last learned about one candidate by sampling its
  timeline, and when (`Vutuv.Tags.Trending`).

  **The census works through the candidates oldest verdict first.** A pass may
  spend only so many sample requests, and one server only so many of those
  (`census_per_host`). Asking loudest first on every pass meant an installation
  reading one server never sampled more than the two loudest candidates, and
  when those two were bot waves, the row stayed empty for good. So a pass asks
  the never-sampled candidates first, then the ones sampled longest ago, and
  `vetted_at` is stamped on **every** outcome, a failed census included. It is
  the scheduler's clock, not a claim that anything was learned — the sweeper
  rule the pull and `Vutuv.Tags.TrendCheck` follow too.

  **A verdict stays good for as long as an offer does**, four passes: a
  candidate the budget did not reach this pass is offered on its last verdict if
  that one passed and is younger than that. Older, it says nothing about today,
  and the row is deleted once its tag stops trending.

  Written only by the pass, in one upsert, so there is no changeset.
  """

  use VutuvWeb, :model

  schema "tag_trend_verdicts" do
    field(:name, :string)

    # `passed` — the sample showed a crowd. `dropped` — it showed a bot wave,
    # too few author servers or too small a sample. `failed` — no sample could
    # be taken at all, which offers nothing either.
    field(:outcome, :string)
    field(:author_hosts, :integer)
    field(:bot_posts, :integer)
    field(:sampled, :integer)
    field(:vetted_at, :utc_datetime)

    timestamps()
  end
end
