defmodule Vutuv.Repo.Migrations.AddHeartbeatToReferenceChecks do
  @moduledoc """
  A liveness stamp on a running check, so one stranded by a reboot or a deploy
  is picked up again in minutes rather than in an hour.

  A check occupies the model for minutes, and the process holding it dies with
  its release: on a blue/green deploy the old slot is stopped mid-inference, and
  a reboot does the same. The row stays `running` with nobody running it, and
  the member watches an hourglass that means nothing.

  Recovery used to key on `updated_at` with a one-hour cutoff, which is a
  reasonable guess at "surely dead by now" precisely because that column says
  nothing about whether anybody is still working. This column does: the worker
  stamps it about once a minute for as long as it is really in the request, so
  `Vutuv.References.Checks.resume_stuck/0` can re-queue on a five-minute
  silence without ever cutting off a slow run that is genuinely in progress.

  Nullable: a check claimed by a release that predates this column has no stamp
  and reads as stale, which is the right answer for a row nobody is heart-
  beating.
  """

  use Ecto.Migration

  def change do
    alter table(:reference_checks) do
      add(:heartbeat_at, :utc_datetime)
    end

    # The recovery sweep runs on every worker boot and every poll, and asks
    # only about running checks — a partial index keeps it off the rest of the
    # table, which is every finished check this installation ever ran.
    create(
      index(:reference_checks, [:heartbeat_at], where: "status = 'running'", name: :reference_checks_running_heartbeat_index)
    )
  end
end
