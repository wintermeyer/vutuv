defmodule Vutuv.Repo.Migrations.AddFediverseNoteInbox do
  use Ecto.Migration

  # Where an answer to this reply has to be delivered (issue #1070).
  #
  # The inbox is already in hand when the note is stored: the inbox verifies
  # every delivery's signature against the sender's freshly fetched actor
  # document, which carries it, and then throws it away. Keeping it means
  # replying costs no network call on the member's request path.
  #
  # Nullable on purpose: notes stored before this column existed have none, and
  # a reply to one of those resolves the inbox on demand instead.
  def change do
    alter table(:fediverse_notes) do
      add(:inbox_uri, :string)
    end
  end
end
