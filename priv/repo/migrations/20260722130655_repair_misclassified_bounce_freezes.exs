defmodule Vutuv.Repo.Migrations.RepairMisclassifiedBounceFreezes do
  use Ecto.Migration

  # One-off repair for the accounts frozen over misclassified bounces. The
  # July 2026 newsletters surfaced ~340 hard bounces at once; the log watcher
  # treated every generic dsn=5.0.0 as a dead recipient, but that bucket (a
  # bare 550/552 reply without an enhanced code) also carries full mailboxes
  # ("552 Quota exceeded") and recipient-side spam/IP blocks - live mailboxes
  # whose owners were then frozen (hidden site-wide) by the grace-period sweep.
  #
  # The classifier now vets 5.0.x by reply text (same release). This re-runs
  # that verdict over the stored evidence: every undeliverable address none of
  # whose ledger rows survives as a confirmed recipient failure is cleared,
  # and its owner re-assessed, which lifts a freeze resting only on
  # misclassified rows. Audit events are written ("misclassified_bounce").
  #
  # Data-only, idempotent, N-1 safe (no schema change). It deliberately calls
  # the repair function shipped in this same release so the migration and the
  # classifier can never disagree; on a fresh database it is a no-op.
  def up do
    %{cleared: cleared, thawed: thawed} = Vutuv.Deliverability.repair_misclassified_bounces()

    IO.puts(
      "repair_misclassified_bounces: cleared #{cleared} addresses, thawed #{thawed} accounts"
    )
  end

  # Not reversible: we deliberately do not re-freeze anyone.
  def down, do: :ok
end
