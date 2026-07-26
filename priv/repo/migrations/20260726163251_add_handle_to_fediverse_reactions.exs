defmodule Vutuv.Repo.Migrations.AddHandleToFediverseReactions do
  use Ecto.Migration

  # The remote account's `preferredUsername`, so a reaction can say WHO it came
  # from instead of only that somebody, somewhere did something.
  #
  # This is not a new category of data about a stranger: `@handle@host` is the
  # very account address `actor_uri` already holds, written the way those
  # networks write it. The inbox has the value in hand anyway — it fetches the
  # actor document to verify the HTTP signature before any row is written — so
  # keeping it costs no extra request and no lookup on the render path.
  # Deliberately still no display name, no avatar, no text.
  #
  # Nullable: rows stored before this migration have none, and
  # `Vutuv.Fediverse.Handle` derives a usable name from the actor URI for them.
  #
  # A plain nullable column -> N-1 safe for the blue/green window.
  def change do
    alter table(:fediverse_reactions) do
      add(:handle, :string)
    end
  end
end
