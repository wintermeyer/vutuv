defmodule Vutuv.Tags.SourceServer do
  @moduledoc """
  What this installation knows about a server a followed tag could read from
  (issue #2128): whether it will hand out a public tag timeline without an
  account, and how big it is.

  One row per host, written by `Vutuv.Tags.SourceServerProbe` and read by the
  tag-source panel to put a figure beside every server it offers. The row is a
  **cache with a clock**, not a record of anything ours: `checked_at` is stamped
  on every outcome, the ones where nothing could be learned included, so an
  unreachable server is not asked again on the next render.

  It sits under `Vutuv.Tags` rather than `Vutuv.Fediverse` because that is what
  it is: the question it answers is a Mastodon **tag timeline**'s, it is fetched
  through the tag pull's own Req seam and gated by the tag pull's own flag, and
  nothing in the fediverse code reads it. A name under `Vutuv.Fediverse` would
  promise a general per-remote-server record this app does not have, and the
  next author wanting one would either widen this or mint a third table.

  `status` is the answer that decides whether a server can be picked at all:

    * `"ok"` — the timeline came back. It can be picked.
    * `"account_required"` — the server answered, and said it only serves this
      to somebody logged in (`401`, `403`, or Mastodon's `422 "This method
      requires an authenticated user"` — see
      `Vutuv.Tags.ExternalTagClient.refusal/1`). Three of the eighteen servers
      measured while shipping this do that. Their OAuth path is a feature of its
      own, so for now the panel shows them and refuses to switch them on.
    * `"unreachable"` — no timeline: DNS, TLS, a `404`, a bad day.

  Everything else on the row is **decoration**, and the probe treats it that
  way: a server with no NodeInfo is still pickable, it simply shows no figures.

  A blocked server never gets a row through the panel at all — the probe refuses
  before the request — but a row written before the operator blocked it can
  outlive the block, so **every reader filters against the blocklist rather than
  trusting the row** (`Vutuv.Tags.SourceServers.offered/0`).
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.BlockedInstance

  @statuses ~w(ok account_required unreachable)

  # What the bounded columns take, published so the probe's clamp and the
  # column's own guard cannot drift apart — the shape `Vutuv.Tags.ExternalPost`
  # already uses for exactly this reason.
  @max_name 255
  @max_description 2_000
  @max_language 16

  @doc "The longest a server's own name may be before the probe clamps it."
  def max_name, do: @max_name

  @doc "The longest a server's own description may be before the probe clamps it."
  def max_description, do: @max_description

  @doc "The longest language code stored."
  def max_language, do: @max_language

  schema "tag_source_servers" do
    field(:host, :string)
    field(:node_name, :string)
    field(:description, :string)
    field(:accounts, :integer)
    field(:active_month, :integer)
    field(:posts, :integer)
    field(:language, :string)
    field(:status, :string)
    field(:checked_at, :utc_datetime)

    timestamps()
  end

  @fields ~w(host node_name description accounts active_month posts language status checked_at)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    |> validate_required([:host, :status, :checked_at])
    |> validate_inclusion(:status, @statuses)
    # Every bounded column here holds a stranger's value, so each is counted in
    # **bytes**: Postgres counts codepoints, Ecto counts graphemes, and in UTF-8
    # the byte count can never be under the codepoint count — the conservative
    # unit is the one Ecto offers. The probe clamps rather than letting these
    # refuse, because dropping a server over the length of its own name is the
    # wrong answer; these are the backstop.
    |> validate_length(:host, max: BlockedInstance.max_host(), count: :bytes)
    |> validate_length(:node_name, max: @max_name, count: :bytes)
    |> validate_length(:description, max: @max_description, count: :bytes)
    |> validate_length(:language, max: @max_language, count: :bytes)
    |> unique_constraint(:host)
  end

  @doc """
  Whether the panel may switch this server on — the `status` half of that
  question, and the only half a stored row can answer.

  `nil` — no row — is "we have never asked", which reads as unavailable rather
  than as available: failing closed here is what keeps a member from adding a
  server the check never actually passed. The operator's blocklist and the
  follow's cap are the other two halves, and they are not on the row, so a
  caller deciding whether a member may pick a server must ask all three
  (`Vutuv.Tags.SourceServers.check/2` does).
  """
  def pickable?(%__MODULE__{status: "ok"}), do: true
  def pickable?(_info), do: false
end
