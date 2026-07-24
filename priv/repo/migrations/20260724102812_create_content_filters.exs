defmodule Vutuv.Repo.Migrations.CreateContentFilters do
  use Ecto.Migration

  # Personal content filters (issue #940): a member's private, viewer-only deny
  # list. Each row mutes a tag or a keyword/phrase (with `*` wildcards) and
  # hides matching posts from that member's own feed. It reveals what a member
  # dislikes, so it is strictly owner-only (never public, never in the agent
  # formats) and belongs in the GDPR export.
  #
  # New table, plain addition -> N-1 safe for the blue/green window.
  def change do
    create table(:content_filters) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      # tag | keyword. A tag entry matches a post's tags; a keyword entry
      # matches the post's body and tags/hashtags.
      add(:kind, :string, null: false)
      # A tag slug/name, or a keyword/phrase with `*` wildcards.
      add(:pattern, :string, null: false)
      # Keyword only: whole-word match by default (so "cess" does not hide
      # "success"); a `*` overrides it locally. Irrelevant for tag rows.
      add(:whole_word, :boolean, null: false, default: true)
      # Optional "snooze": null = permanent. (Column now, UI later.)
      add(:expires_at, :utc_datetime)

      timestamps()
    end

    # The feed compiles a member's whole list on every page, so read them by
    # owner in one shot.
    create(index(:content_filters, [:user_id]))

    # One row per (owner, kind, pattern): re-muting the same thing is a no-op,
    # not a duplicate.
    create(unique_index(:content_filters, [:user_id, :kind, :pattern]))
  end
end
