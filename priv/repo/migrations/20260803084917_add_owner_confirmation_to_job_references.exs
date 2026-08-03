defmodule Vutuv.Repo.Migrations.AddOwnerConfirmationToJobReferences do
  @moduledoc """
  When the member affirmed that the Zeugnis they are filing is theirs to file.

  A Zeugnis is a named person's employment history plus a graded judgement of
  them, and here it is also read by a language model. Uploading somebody
  else's, without that person's agreement, is not a policy question but a
  processing of another human's personal data with no basis for it.

  The stamp is the point. A sentence on the form is unenforceable and leaves
  nothing behind; this is the same arrangement `public_consented_at` already
  uses one field over — the choice **and the evidence that it was made** — so
  when somebody writes in a year later saying "that is my Zeugnis", the
  operator can say what was affirmed and when.

  Nullable: it is asked when an entry is created, and the entries that predate
  the column were never asked.
  """

  use Ecto.Migration

  def change do
    alter table(:job_references) do
      add(:owner_confirmed_at, :utc_datetime)
    end
  end
end
