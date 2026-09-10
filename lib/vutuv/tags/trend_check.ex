defmodule Vutuv.Tags.TrendCheck do
  @moduledoc """
  When this installation last asked one server what is trending on it, and when
  it will ask again (issue #2129).

  One row per server the operator named in `:tag_source_servers`, minted the
  first time a pass comes round to it.

  **`checked_at` is stamped on every outcome**, the ones where nothing could be
  learned included — a blocked host, a server having a bad minute. It is the
  scheduler's clock, not a claim that anything was answered. A row that never
  moves is due again on the very next tick of the two-minute loop, which here
  does not slow one server down but makes the **whole pass** run fifteen times
  too often: the pass is due when *any* server is, and it asks all of them. That
  is issue #1316's deadlock in this feature's shape.

  **`next_check_at` is uniform on purpose** — every outcome gets the same
  interval, and there is no backoff at all. A divergent one would let a
  recovered server come due on its own, and a pass asking one server would
  recompute "how many servers is this tag busy on" from a single answer and
  empty the offer; uniformity is what keeps the spread a real measurement.
  Which is also why there is no strike counter here, unlike the pull's own
  schedule next door — nothing would read it. The politeness this gives up is
  small: one small `GET` per server per interval, 48 a day at the shipped half
  hour, against the pull's own floor of 144 a day for a single (tag, server)
  pair.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.BlockedInstance

  # `listed` — trending tags came back. `empty` — the server answered and named
  # none. `skipped` — it could not be asked at all (blocked, an internal
  # address): nobody's fault and no strike. `failed` — the remote side did not
  # answer, or answered something that was not a list.
  @outcomes ~w(listed empty skipped failed)

  schema "tag_trend_servers" do
    field(:host, :string)
    field(:checked_at, :utc_datetime)
    field(:next_check_at, :utc_datetime)
    field(:last_outcome, :string)

    timestamps()
  end

  @fields ~w(host checked_at next_check_at last_outcome)a
  @required ~w(host checked_at next_check_at)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    |> validate_required(@required)
    |> validate_length(:host, max: BlockedInstance.max_host(), count: :bytes)
    |> validate_inclusion(:last_outcome, @outcomes)
    |> unique_constraint(:host)
  end
end
