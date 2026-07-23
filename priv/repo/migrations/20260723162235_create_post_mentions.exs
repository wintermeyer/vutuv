defmodule Vutuv.Repo.Migrations.CreatePostMentions do
  use Ecto.Migration

  # Who a post names with `@handle`, resolved to members once at write time.
  #
  # A mention is plain text inside `posts.body` — nothing structured is stored —
  # so deriving "who was mentioned" the way the rest of the notifications feed
  # derives its events would mean an ILIKE scan over every post on every unread
  # count, and that count runs on every page render for the shell badge. This
  # table is that scan done once, at save time, so the feed source becomes one
  # indexed lookup. It is the second notification kind needing its own table,
  # for a kindred reason to `handle_change_notifications`.
  #
  # Both sides cascade: the row says "this post names this member" and is
  # meaningless once either is gone.

  def up do
    create table(:post_mentions) do
      add(:post_id, references(:posts, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      timestamps()
    end

    # One row per (post, member): a body naming someone three times is one
    # mention. Also the conflict target when a post is saved again.
    create(unique_index(:post_mentions, [:post_id, :user_id]))
    # The feed source — "everything that mentioned me", newest first.
    create(index(:post_mentions, [:user_id, :inserted_at]))

    flush()

    backfill()
  end

  def down do
    drop(table(:post_mentions))
  end

  # Existing posts get their mentions recorded too, so the kind is retroactive
  # like every other one in this feed: someone mentioned last week sees it the
  # first time they open /notifications after this ships.
  #
  # The grammar lives in `Vutuv.Mentions` and is deliberately called rather than
  # re-implemented here — a backfill that disagreed with the running code about
  # what counts as a mention would be worse than no backfill at all. Bodies
  # without an `@` short-circuit inside `local_handles/1`.
  #
  # Timestamps and the UUID v7 id are stamped from the **post**, not from now,
  # so a backfilled mention lands in the feed at the moment it was written
  # instead of bunching every historical mention onto deploy day — and so the
  # id keeps sorting by creation time like every other id in the schema.
  #
  # Every id is passed as `$n::text::uuid` (and matched as `id::text`): raw
  # Postgrex wants a 16-byte binary for a bare `uuid` parameter, so the cast
  # keeps the parameter a plain string, the way the `RepairMilkdownEscaped*`
  # migrations do it. The two timestamps are read off the `posts` row inside
  # the statement rather than round-tripped through Elixir.
  defp backfill do
    %{rows: users} = repo().query!("SELECT id::text, username FROM users", [])
    by_handle = Map.new(users, fn [id, username] -> {username, id} end)

    %{rows: posts} =
      repo().query!("SELECT id::text, user_id::text, body, inserted_at FROM posts", [])

    for [post_id, author_id, body, at] <- posts,
        is_binary(body),
        user_id <- resolve(body, by_handle),
        user_id != author_id do
      repo().query!(
        """
        INSERT INTO post_mentions (id, post_id, user_id, inserted_at, updated_at)
        SELECT $1::text::uuid, p.id, $2::text::uuid, p.inserted_at, p.inserted_at
        FROM posts p WHERE p.id::text = $3
        ON CONFLICT DO NOTHING
        """,
        [Vutuv.UUIDv7.generate_at(at), user_id, post_id]
      )
    end
  end

  defp resolve(body, by_handle) do
    body
    |> Vutuv.Mentions.local_handles()
    |> Enum.flat_map(&List.wrap(Map.get(by_handle, &1)))
    |> Enum.uniq()
  end
end
