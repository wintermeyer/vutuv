defmodule Vutuv.Repo.Migrations.AddAuthorHostToExternalTagPosts do
  use Ecto.Migration

  # The two facts a reader of `external_tag_posts` needs and #2126 had no reader
  # for (issue #2127).
  #
  # **`author_host` — whose server this really is.** A tag timeline carries
  # other servers' posts: a post about Koblenz read off troet.cafe was usually
  # written somewhere else entirely, and `source` names only where we looked.
  # The client already computes the author's host to ask the blocklist about it
  # and then throws it away; storing it is what lets the card name the author's
  # own address and lets the operator's blocklist be a plain column comparison
  # instead of a `split_part` fragment repeated in every query that reads this
  # table.
  #
  # `:string` and not `:text`, taking the type from the column it sits beside:
  # `source` is a hostname too, and both are bounded by
  # `Vutuv.Fediverse.BlockedInstance.max_host/0` in the changeset.
  #
  # **`reported_at` — a tombstone, not a deletion.** A reported row keeps its
  # key and loses its words, because this table is re-read on a loop and a
  # deleted row would simply be written back; `Vutuv.Tags.ExternalPosts.report/2`
  # owns that reasoning.
  #
  # Both are nullable, which is what makes this N-1 safe: the currently
  # deployed release keeps writing rows through the blue/green window and knows
  # neither column. A row with no `author_host` is one this release cannot say
  # anything true about, so the readers **fail closed** and leave it out; the
  # per-tag cap of 20 rolls those few out again within hours.
  def change do
    alter table(:external_tag_posts) do
      add(:author_host, :string)
      add(:reported_at, :utc_datetime)
    end

    # What the old release stored, read the way the client reads it: the part of
    # `acct` after the `@`, and the queried server itself for an author local to
    # it. Deterministic, and the same rule the client applies at write time.
    execute(
      """
      UPDATE external_tag_posts
         SET author_host = coalesce(nullif(split_part(author_acct, '@', 2), ''), source)
       WHERE author_host IS NULL
      """,
      "SELECT 1"
    )

    # The feed's own path through this table (issue #2127): the member's follows
    # give it a (tag, server) pair and it wants the newest first. Without this
    # the pair is a join filter over the unique index on
    # `(tag_id, source, remote_id)` — whose third column is a remote id, so it
    # can order nothing — and every call sorts every showable row of every tag
    # the member follows. At the shipped cap of twenty posts per tag that is
    # cheap either way; the cap is operator-settable and a merged tag can carry
    # several tags' worth at once, which is where it stops being.
    create(index(:external_tag_posts, [:tag_id, :source, :published_at]))
  end
end
