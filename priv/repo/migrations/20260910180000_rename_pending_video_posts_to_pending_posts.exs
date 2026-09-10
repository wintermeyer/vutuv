defmodule Vutuv.Repo.Migrations.RenamePendingVideoPostsToPendingPosts do
  use Ecto.Migration

  # A post no longer waits only for a clip (issue #2106): it waits for whatever
  # media it carries — the clip, the files, their preview pages and the AI
  # check on each of those — and publishes the moment the last one is done. So
  # `pending_video_posts` is now `pending_posts`.
  #
  # ## The rename is the **expand** half, and only that
  #
  # Deploys here are blue/green: this runs while the PREVIOUS release is still
  # serving traffic, and that release keeps reading and writing
  # `pending_video_posts` until nginx switches. A bare `ALTER TABLE … RENAME`
  # would 500 every waiting card on the live slot for the length of the switch.
  #
  # So the table is renamed and the old name is put back as a **view** over it.
  # A single-table view with nothing but plain column references is
  # auto-updatable in Postgres, so the old release's SELECT, INSERT, UPDATE and
  # DELETE all keep working, against the same rows the new release sees — one
  # table, two names, no data split during the overlap.
  #
  # The view names its columns explicitly rather than `SELECT *` (which is
  # expanded once at creation anyway): that is what says in the source which
  # columns the deployed release knows about, and it is why every column added
  # below must be nullable or carry a default — an INSERT through the view
  # cannot fill one it cannot see.
  #
  # **The contract deploy drops the view** (`DROP VIEW pending_video_posts`),
  # and that becomes safe once no deployed release names it — i.e. one deploy
  # after this one.
  @view_columns ~w(id user_id video_id kind parent_post_id organization_id note_id
                   remote_post_id attrs status post_id error inserted_at updated_at)

  def up do
    rename(table(:pending_video_posts), to: table(:pending_posts))

    execute("""
    CREATE VIEW pending_video_posts AS
    SELECT #{Enum.join(@view_columns, ", ")} FROM pending_posts
    """)

    alter table(:pending_posts) do
      # The scheduler's clock (`Vutuv.Posts.Pending.due/1`). The sweeper picks
      # waiting rows least-recently-looked-at first and stamps this on EVERY
      # outcome, the ones where nothing could be done included — a row whose
      # media are still working would otherwise hold the front of every batch
      # for ever while looking idle.
      add(:checked_at, :utc_datetime)

      # The id the post will get, minted before the create path runs and
      # written at claim time. Deliberately **not** a reference: it names a row
      # that does not exist yet, and a foreign key would refuse the write. It is
      # what makes a resumed publish idempotent — a slot killed between the
      # insert and the bookkeeping leaves a row in `publishing` whose post is
      # already there, and the resume finds it by this id instead of writing the
      # member's post a second time.
      add(:minted_post_id, :binary_id)
    end

    # The due query: waiting and publishing rows, oldest clock first. Partial,
    # because a published or cancelled row is history and never comes back.
    create(
      index(:pending_posts, [:checked_at],
        where: "status IN ('waiting', 'publishing')",
        name: :pending_posts_due_index
      )
    )

    # The author's own page (`/system/uploads`) and the app bar's chip.
    create(index(:pending_posts, [:user_id, :inserted_at]))

    alter table(:attachments) do
      # Which waiting post holds this file. The file's own parents stay the
      # nullable `post_id`/`message_id` pair — this is a **reservation**, not a
      # third parent: it keeps the daily sweep and a re-mounted composer off a
      # file that a post is already waiting on, and it is cleared the moment the
      # post claims the file for real.
      add(
        :pending_post_id,
        references(:pending_posts, type: :binary_id, on_delete: :nilify_all)
      )

      # When the AI check refused one of this file's preview pages. The page
      # itself is deleted by the verdict, so without this the file would look
      # untouched and the post would wait for a page that is never coming back.
      add(:refused_at, :utc_datetime)
    end

    create(index(:attachments, [:pending_post_id], where: "pending_post_id IS NOT NULL"))
  end

  def down do
    drop(index(:attachments, [:pending_post_id], where: "pending_post_id IS NOT NULL"))

    alter table(:attachments) do
      remove(:refused_at)
      remove(:pending_post_id)
    end

    drop(index(:pending_posts, [:user_id, :inserted_at]))
    drop(index(:pending_posts, [:checked_at], name: :pending_posts_due_index))

    alter table(:pending_posts) do
      remove(:minted_post_id)
      remove(:checked_at)
    end

    execute("DROP VIEW pending_video_posts")
    rename(table(:pending_posts), to: table(:pending_video_posts))
  end
end
