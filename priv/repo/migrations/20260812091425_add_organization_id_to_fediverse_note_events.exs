defmodule Vutuv.Repo.Migrations.AddOrganizationIdToFediverseNoteEvents do
  use Ecto.Migration

  # The takedown ledger recorded `user_id` = whose page the removed reply sat
  # on, and NULL for content that sat on nobody's (a cached post). An
  # organization post is a third case: it sits on a page, and reading a NULL
  # there as "nobody's" would be untrue.
  #
  # A plain nullable column, so the release still serving traffic during the
  # deploy keeps working (it simply never writes it).
  def change do
    alter table(:fediverse_note_events) do
      add(:organization_id, :binary_id)
    end
  end
end
