defmodule Vutuv.Fediverse.Delivery do
  @moduledoc """
  One queued outbound ActivityPub delivery: an activity (JSON, built at
  enqueue time) headed for one remote inbox, signed with the member's actor
  key when `Vutuv.Fediverse.Deliverer` sends it. Mirrors the webhook queue:
  exponential backoff on failure, dropped after repeated failure, row deleted
  on success.

  `rebuild_from` marks the one row that does **not** send the copy built at
  enqueue time (issue #1070): a post whose picture the AI scan had not released
  yet is held briefly and re-rendered when it goes out, so the picture rides
  along. `activity_json` still holds a complete, valid activity for such a row, so
  a release that does not know this column delivers that instead of choking — the
  worst a deploy window can do is federate one post without its picture.
  """

  use VutuvWeb, :model

  schema "fediverse_deliveries" do
    field(:inbox_uri, :string)
    field(:activity_json, :string)
    field(:rebuild_from, :string)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)

    # The sender is a member OR a page (issue #1334), CHECK-enforced to exactly
    # one. No unique index: a delivery row is a queue entry, not a relationship.
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)

    timestamps()
  end
end
