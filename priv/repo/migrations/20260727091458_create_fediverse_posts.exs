defmodule Vutuv.Repo.Migrations.CreateFediversePosts do
  use Ecto.Migration

  # What a followed account posts, cached so it can appear in the follower's
  # home feed (issue #1161).
  #
  # One row per remote post, **not** one per follower: several members here can
  # follow the same account, and the post is the same post. That is what
  # `object_uri` being unique enforces, and it is why the row hangs off the
  # account rather than off a follow.
  #
  # The retention triple is the whole legal footing, exactly as for the cached
  # replies (`fediverse_notes`, issue #1069), because the situation is the same:
  # consent from somebody on another server is not obtainable, so the copy is
  # bounded instead. `published_at` is the author's own stamp and orders the
  # feed; `received_at` is when it reached us; `expires_at` is the hard ceiling
  # the sweeper enforces. There is deliberately no `checked_at` and no freshness
  # re-fetch: a followed account's stream is pushed to us continuously, so an
  # `Update` or a `Delete` arrives on its own, and re-asking a server about every
  # cached post of every account our members read would be a far heavier thing
  # than the per-reply check it would resemble.
  #
  # No avatar column and no picture of any kind - those are issue #1163.
  #
  # New table only -> N-1 safe for the blue/green window.
  def change do
    create table(:fediverse_posts) do
      add(
        :remote_account_id,
        references(:fediverse_remote_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # The post's own AP id. Unique: a redelivery (once per follower, until the
      # shared inbox of issue #1073 is what every server uses) stores one row,
      # and an upstream Update/Delete finds it on this key. `text` with a byte
      # cap in the schema, because it carries a btree unique index.
      add(:object_uri, :text, null: false)
      # What it answered, when it answered something. Only a continuation of the
      # author's OWN stored thread is kept, so this always names another row of
      # this table; a reply into somebody else's conversation is dropped at the
      # door rather than stored and then hidden.
      add(:in_reply_to_uri, :text)
      # Where a human reads the original.
      add(:origin_url, :text)

      # Plain text, never HTML: nothing a stranger wrote is ever rendered raw.
      add(:content_text, :text, null: false)
      # The content warning, if it carried one. Its own column rather than folded
      # into the text, because a warning exists precisely so the reader chooses
      # whether to read what is behind it.
      add(:summary, :text)
      # The author marked the post sensitive. Kept apart from the warning: a
      # server may set one without the other, and only the author can say it.
      add(:sensitive, :boolean, null: false, default: false)

      # public | unlisted | followers. Anything narrower (a direct message, an
      # audience we cannot read) is never stored, so there is no "unknown" here
      # the way there is on a reply: a reply had to be kept in order to be shown
      # to its addressee, a post nobody here was addressed in does not.
      add(:audience, :string, null: false)
      # note | question. A poll's options ride in the text with a link back to
      # vote at the origin, since carrying a vote is not something we can do.
      add(:kind, :string, null: false, default: "note")

      # The author's own stamp, clamped against the future so a server cannot
      # pin itself to the top of somebody's feed forever. This orders the feed;
      # `received_at` is our own clock and orders nothing.
      add(:published_at, :utc_datetime, null: false)
      add(:received_at, :utc_datetime, null: false)
      add(:expires_at, :utc_datetime, null: false)
    end

    create(unique_index(:fediverse_posts, [:object_uri]))

    # The feed's read. It is NOT per account: the query asks for the newest
    # posts across every account the viewer follows, and Postgres cannot merge N
    # per-account index scans into one global order — without this it collects
    # every cached post of every followed account and top-N sorts them, on every
    # feed render and every "Load more". Ordered the way the query is, so the
    # planner walks it backwards and stops after a page. `id` is the tiebreaker
    # the cursor pages on.
    create(index(:fediverse_posts, [:published_at, :id]))

    # One account's posts: the thread check on ingestion, and the purge that
    # runs when nobody here follows the author any more.
    create(index(:fediverse_posts, [:remote_account_id, :published_at]))

    # The sweeper's read.
    create(index(:fediverse_posts, [:expires_at]))
  end
end
