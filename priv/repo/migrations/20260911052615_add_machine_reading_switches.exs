defmodule Vutuv.Repo.Migrations.AddMachineReadingSwitches do
  use Ecto.Migration

  # Issue #2107: one member-level decision about machines, stamped onto every
  # post as it is published, plus the composer's file question.
  #
  # `users.posts_machines_allowed?` is a `Vutuv.Prefs` key, so it follows that
  # layer's shape exactly: **nullable, no database default**. NULL means "never
  # asked, inherit the installation default" and is what distinguishes it from
  # a member who deliberately chose the shipped value — which is the whole
  # reason an operator can move the default later without touching 6,000 rows.
  #
  # `posts.noindex_noai?` is the member's answer **frozen at publish time**,
  # true meaning no machines. Not read back from the member afterwards: a post
  # keeps what it went out with, so changing the setting leaves every older
  # post exactly as it was. `false` is what every post written so far means —
  # nobody was asked, and a backfill to "no" would have withdrawn six years of
  # posts from search and from every server that already holds a copy.
  #
  # `posts.strip_metadata?` is the composer's own switch, the author's *answer*
  # about their files rather than a record of what happened — that is
  # `attachments.metadata_stripped_at`, written by the qpdf run itself. It
  # defaults to `true` (the switch's own default) so a post inserted by the
  # previous release during the blue/green overlap carries the answer the
  # composer would have sent.
  #
  # All five columns are plain additions, so the deployed release keeps reading
  # and writing these tables without naming any of them (N-1). The overlap
  # window is not merely short, it is **empty**: nothing writes
  # `users.posts_machines_allowed?` before this release, so no post the old slot
  # inserts during the switch can carry a member's "no" that the column default
  # would then contradict.
  def change do
    alter table(:users) do
      add(:posts_machines_allowed?, :boolean)
    end

    alter table(:posts) do
      add(:noindex_noai?, :boolean, default: false, null: false)
      add(:strip_metadata?, :boolean, default: true, null: false)
    end

    # The file question travels through the draft, so a reload brings it back
    # beside the words it was chosen with. Nullable, unlike the post's column:
    # a draft written before this deploy has no answer, and the composer must
    # fall back to its own default rather than to a stored `false` nobody
    # chose. The machines question has no draft column on purpose — it is not
    # asked in the composer any more.
    alter table(:post_drafts) do
      add(:strip_metadata?, :boolean)
    end

    # When this file's served copy was rewritten without its metadata. NULL
    # means "still verbatim" — either qpdf is not on this box, the file is not
    # a PDF, or the author asked for the metadata to stay. The column is the
    # only thing that can tell "cleaned" from "never asked" once the bytes are
    # on disk, which is what lets the answer be changed later without guessing.
    alter table(:attachments) do
      add(:metadata_stripped_at, :utc_datetime)
    end
  end
end
