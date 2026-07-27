defmodule Vutuv.Experiments.Stat do
  @moduledoc """
  One day's counters for one variant of one experiment.

  Aggregate only — the row says "variant B was shown 412 times on 2026-07-28",
  never who saw it. Nothing here is written from user input, so there is no
  changeset: `Vutuv.Experiments` inserts and increments these rows directly.
  """

  use VutuvWeb, :model

  schema "experiment_stats" do
    field(:experiment, :string)
    field(:variant, :string)
    field(:day, :date)

    # Landing pages that showed this variant (once per browser session).
    field(:views, :integer, default: 0)
    # Sign-up forms that created an account from such a page.
    field(:signups, :integer, default: 0)
    # Those accounts that then confirmed their PIN and became real members.
    field(:confirmations, :integer, default: 0)

    timestamps()
  end
end
