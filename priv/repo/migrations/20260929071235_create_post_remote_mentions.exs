defmodule Vutuv.Repo.Migrations.CreatePostRemoteMentions do
  use Ecto.Migration

  @moduledoc """
  The accounts on other networks a post of ours names as `@user@host`.

  One row per (post, address). `remote_account_id` stays NULL until the address
  is resolved (WebFinger, then the actor document); the row is also the state
  of that resolution, so a task a deploy killed is picked up again by the
  sweeper instead of being lost. `attempts` and `attempted_at` are that
  sweeper's clock.

  A resolved row is what lets the Note carry a `Mention` tag (so the person is
  notified), puts their inbox among the recipients, and keeps their account
  row from being purged, which is what keeps the mention's link on their real
  profile page.
  """

  def change do
    create table(:post_remote_mentions) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:remote_account_id, references(:fediverse_remote_accounts, on_delete: :delete_all))
      # `user@host`, lowercased. `text` because a host alone may run to 253
      # bytes; the schema caps the whole at 320, which keeps the unique entry
      # far below Postgres' btree limit.
      add(:address, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:attempted_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:post_remote_mentions, [:post_id, :address]))
    create(index(:post_remote_mentions, [:remote_account_id]))

    # The sweeper's due query: rows still to resolve, oldest attempt first,
    # in the order it asks for. The `3` is `@mention_attempts`: a row that has
    # given up leaves the index.
    create(
      index(:post_remote_mentions, ["attempted_at ASC NULLS FIRST", :id],
        where: "remote_account_id IS NULL AND attempts < 3",
        name: :post_remote_mentions_pending_index
      )
    )
  end
end
