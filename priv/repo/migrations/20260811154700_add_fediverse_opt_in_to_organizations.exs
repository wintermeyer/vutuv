defmodule Vutuv.Repo.Migrations.AddFediverseOptInToOrganizations do
  @moduledoc """
  Issue #1334: a page decides for itself whether it federates, the way a member
  does through `users.fediverse_followers?`.

  **Default false, and that is the load-bearing part.** Everything else in this
  half — WebFinger, the actor document, the collections, the inbox, delivery —
  is gated on this flag, which is what lets those pieces land one at a time
  without any of them being visible to another server before the chain is
  complete. A page that never switches it on behaves exactly as it does today:
  its actor URLs 404, the same way an un-federated member's do.

  Federating is also the kind of decision that cannot be fully taken back — once
  a remote server holds a copy of a post, deleting here only *asks* it to
  forget — so the default has to be off and the switch has to be deliberate.

  N-1 safe: a plain nullable column with a default; the previous release never
  reads it.
  """
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add(:fediverse_followers?, :boolean, default: false, null: false)
    end
  end
end
