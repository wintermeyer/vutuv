defmodule Vutuv.Repo.Migrations.CreateFediversePostLookups do
  use Ecto.Migration

  @moduledoc """
  A post a member here fetched by pasting its URL (issue #1211).

  ActivityPub only pushes what happens after a follow is accepted, so a post
  published before that never arrives and there is nothing here to reply to,
  like or reshare. The lookup page fetches one on demand — and because it works
  for **any** account, not only followed ones, the copy it leaves behind often
  has no follower holding it.

  That is what this row is for. `purge_unfollowed_remote_posts/0` deletes the
  cached posts of every account nobody follows any more; this row is the third
  reason a copy may stay, beside a member's reshare and a followed account's
  boost. It buys the post nothing more than the right to live out the ordinary
  `FEDIVERSE_POST_RETENTION_DAYS` clock — the ceiling sweep ignores it, so a
  looked-up post expires like every other cached copy.

  One row per (member, post): a second lookup of the same post by the same
  member is the same claim, and the unique index makes re-pasting a URL a no-op
  rather than a pile of rows.

  It also adds an index on `fediverse_posts.origin_url`. A pasted post URL is
  usually the **display** URL (`https://host/@user/123`), while the row is keyed
  on the canonical object id (`https://host/users/user/statuses/123`), so
  recognizing an already-cached post — the case that must cost neither a request
  nor a slot of the member's budget — has to look at both columns.
  """

  def change do
    create table(:fediverse_post_lookups) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:fediverse_post_lookups, [:user_id, :remote_post_id]))
    # The cascade's own index, and the "is anything still holding this cached
    # post" question the unfollowed purge asks.
    create(index(:fediverse_post_lookups, [:remote_post_id]))

    # Capped at 2,048 bytes by `Vutuv.Fediverse.RemotePost`, so a btree entry
    # stays well inside Postgres' key limit.
    create(index(:fediverse_posts, [:origin_url]))
  end
end
