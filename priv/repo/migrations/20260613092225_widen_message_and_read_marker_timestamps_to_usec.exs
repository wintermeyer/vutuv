defmodule Vutuv.Repo.Migrations.WidenMessageAndReadMarkerTimestampsToUsec do
  use Ecto.Migration

  # Issue #776 (4b): the read marker `participants.last_read_at` is set to
  # `max(messages.inserted_at)`, but both columns were `timestamp(0)` (second
  # precision). A message arriving in the SAME wall-clock second as a read got
  # `inserted_at == last_read_at`, so the strict `inserted_at > last_read_at`
  # unread test read it as already-read — contradicting the moduledoc promise
  # that "a message arriving during the read stays unread".
  #
  # Widening these to microsecond precision (`timestamp(6)` + the schemas'
  # `:naive_datetime_usec`) shrinks that window from a full second to a
  # microsecond. Postgres stores timestamps at microsecond precision
  # internally regardless of the typmod, so raising the typmod from 0 to 6 is
  # a metadata-only change — no table rewrite, no scan — and existing
  # second-rounded values keep their value. Backward compatible (N-1): the
  # previously deployed release rounds its writes to seconds anyway and reads
  # the wider values fine.
  def up do
    alter table(:messages) do
      modify(:inserted_at, :naive_datetime_usec)
      modify(:updated_at, :naive_datetime_usec)
    end

    alter table(:conversation_participants) do
      modify(:last_read_at, :naive_datetime_usec)
    end
  end

  def down do
    alter table(:messages) do
      modify(:inserted_at, :naive_datetime)
      modify(:updated_at, :naive_datetime)
    end

    alter table(:conversation_participants) do
      modify(:last_read_at, :naive_datetime)
    end
  end
end
