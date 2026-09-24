defmodule Vutuv.Repo.Migrations.AddLikeNotificationThrottle do
  use Ecto.Migration

  # Additive only, so the release still serving during the switch keeps
  # working: it never writes the new columns and their defaults cover it.
  def change do
    # The member's cap on announced likes per post (a Vutuv.Prefs knob): nil
    # inherits the installation default, like every other pref column.
    alter table(:users) do
      add(:like_notification_cap, :string)
    end

    # Stamped when the like arrived past the author's single likes and was not
    # a milestone (Vutuv.Activity.LikeThrottle): the row still counts on the
    # post, it just never rang the bell. Postgres 11+ adds a constant default
    # without rewriting the table.
    alter table(:post_likes) do
      add(:quiet, :boolean, null: false, default: false)
    end

    alter table(:fediverse_reactions) do
      add(:quiet, :boolean, null: false, default: false)
    end

    # The author muted notifications about this post (its ⋯ menu), and the
    # highest like milestone already announced, so an unlike and a like again
    # never ring the same one twice.
    alter table(:posts) do
      add(:notifications_muted_at, :utc_datetime)
      add(:like_milestone_announced, :integer, null: false, default: 0)
    end

    # The bell's tally asks "which of my posts are muted" on every recount. A
    # partial index keeps that an empty probe instead of a walk over every post
    # the member ever wrote, and it stays tiny because almost nothing is muted.
    create(
      index(:posts, [:user_id],
        where: "notifications_muted_at IS NOT NULL",
        name: :posts_muted_by_user_index
      )
    )
  end
end
