defmodule Vutuv.Repo.Migrations.AddMemberIdToWebhookDeliveries do
  use Ecto.Migration

  # Which member's event a queued delivery carries, so `deliver_due/0` can ask
  # again whether they still authorize the app — the grant was checked once, at
  # emit, and a revocation therefore did not reach anything already queued or
  # retrying (the backoff ladder runs about four hours).
  #
  # Nullable, and it stays nullable: a `ping` has no member and no grant, and
  # rows queued by the release before this one have no member recorded. Both are
  # exempted in the query rather than backfilled — a ping legitimately, an old
  # row because guessing its member from the payload slug would be inventing
  # the fact this column exists to record.
  #
  # A plain nullable add plus an index, so the currently deployed release keeps
  # working unchanged (N-1).
  def change do
    alter table(:webhook_deliveries) do
      add(:member_id, references(:users, on_delete: :delete_all, type: :binary_id))
    end

    create(index(:webhook_deliveries, [:member_id]))
  end
end
