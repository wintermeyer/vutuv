defmodule Vutuv.Tags.ExternalFetch do
  @moduledoc """
  The schedule of one (tag, server) pull (issue #2126): when this installation
  last read that server's timeline for that tag, and when it will look again.

  One row per pair anybody here wants, minted the first time the pair comes up
  and kept for as long as somebody names that server on that tag
  (`Vutuv.Tags.ExternalPosts.prune/0` takes it away with the last follow that
  wanted it).

  **`checked_at` is stamped on every outcome**, a skip included. It is the
  scheduler's clock, not a claim that the question was asked: a pair that can
  never be fetched — the operator blocked the host, the host resolves somewhere
  internal — leaves the due set for its next interval like everything else. The
  alternative is the deadlock issue #1316 already ran in production: an
  unworkable item whose clock never moves is due again two minutes later, for
  good, and since the due query serves the least recently done first it then
  holds the front of every batch and spends the whole cap on questions nobody
  can answer.

  `strikes` counts consecutive failures of the **remote** side only. A skip
  takes none — the server did nothing wrong, and a host may be unblocked
  tomorrow.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.BlockedInstance

  @outcomes ~w(stored empty skipped failed)

  schema "external_tag_fetches" do
    field(:source, :string)
    field(:checked_at, :utc_datetime)
    field(:next_fetch_at, :utc_datetime)
    field(:interval_seconds, :integer)
    field(:strikes, :integer, default: 0)
    field(:last_outcome, :string)

    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  @fields ~w(tag_id source checked_at next_fetch_at interval_seconds strikes last_outcome)a
  @required ~w(tag_id source checked_at next_fetch_at interval_seconds)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    |> validate_required(@required)
    |> validate_length(:source, max: BlockedInstance.max_host())
    |> validate_inclusion(:last_outcome, @outcomes)
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:strikes, greater_than_or_equal_to: 0)
    |> unique_constraint(:source, name: :external_tag_fetches_tag_id_source_index)
    |> foreign_key_constraint(:tag_id)
  end
end
