defmodule Vutuv.Repo.Migrations.AddAutoPostDeletionToUsers do
  use Ecto.Migration

  # Automatic deletion of a member's own posts after a configurable age
  # (issue #1255). Plain additions, so the currently deployed release keeps
  # working untouched: it never reads these columns, and every default is the
  # behaviour it already has (the switch off, nothing deleted).
  #
  # Deliberately NOT a Vutuv.Prefs knob: prefs resolve member -> admin ->
  # shipped default, and no installation admin may set a default that starts
  # deleting members' posts. Every column carries the safe value, and nothing
  # backfills.
  def change do
    alter table(:users) do
      add(:auto_post_deletion?, :boolean, default: false, null: false)
      # NULL until the member picks an age; the switch cannot be turned on
      # without one (see Vutuv.Accounts.User).
      add(:auto_post_deletion_after_days, :integer)

      # The exceptions. Default true = keep more: whoever enables the switch
      # without reading the page loses the least.
      add(:auto_post_deletion_keep_photos?, :boolean, default: true, null: false)
      add(:auto_post_deletion_keep_answered?, :boolean, default: true, null: false)
      add(:auto_post_deletion_keep_bookmarked?, :boolean, default: true, null: false)

      # Your own replies in other people's threads. Default false = kept: a
      # reply lives inside a conversation that is not only yours.
      add(:auto_post_deletion_delete_replies?, :boolean, default: false, null: false)

      # Engagement floors, 0 = off.
      add(:auto_post_deletion_min_likes, :integer, default: 0, null: false)
      add(:auto_post_deletion_min_bookmarks, :integer, default: 0, null: false)
      add(:auto_post_deletion_min_reposts, :integer, default: 0, null: false)

      # The sweeper's own clock: the Berlin day this member was last swept.
      # Stamped on EVERY pass, including the ones that delete nothing, so an
      # unworkable member cannot hold the front of the oldest-first batch.
      add(:auto_post_deletion_swept_on, :date)
    end

    # The nightly pass selects "switched on, least recently swept first". A
    # partial index keeps that scan proportional to the members who enabled
    # the feature rather than to the whole table.
    create(
      index(:users, [:auto_post_deletion_swept_on],
        where: "\"auto_post_deletion?\" = true",
        name: :users_auto_post_deletion_due_index
      )
    )
  end
end
