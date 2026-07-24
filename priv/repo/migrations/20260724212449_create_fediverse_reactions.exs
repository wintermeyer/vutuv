defmodule Vutuv.Repo.Migrations.CreateFediverseReactions do
  use Ecto.Migration

  # What other networks did with a member's post (issue #1068): one minimal row
  # per remote person per post per kind, so the member can be shown a count.
  #
  # Deliberately counts only. No display name, no avatar, no text — the actor
  # URI is here for exactly two reasons: each person counts once, and an
  # upstream Undo can find its row. Nothing else about a third party is stored,
  # which is what makes data minimisation plus a working deletion path the legal
  # footing rather than a consent we could never obtain from them.
  #
  # A row lives exactly as long as the post it belongs to (the FK cascade), the
  # way a vutuv like does; there is no separate expiry.
  #
  # Plus the member's off-switch: on by default for anyone who already
  # federates, since they are already publishing outward and this is only the
  # answer coming back. Turning it off drops the rows.
  #
  # New table + new column with a default -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_reactions) do
      add(:post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false)
      # The remote actor's id URI. `text`, because remote URIs are unbounded in
      # theory; the schema caps the length before anything is written.
      add(:actor_uri, :text, null: false)
      # like | announce (a favourite, or a re-share).
      add(:kind, :string, null: false)
      add(:received_at, :utc_datetime, null: false)
    end

    # One row per (post, person, kind): a repeat Like is an upsert, never a
    # second vote, and an Undo finds its row on this index. It is also the index
    # the per-post count reads.
    create(unique_index(:fediverse_reactions, [:post_id, :actor_uri, :kind]))

    alter table(:users) do
      add(:fediverse_reactions?, :boolean, null: false, default: true)
    end
  end
end
