defmodule Vutuv.Repo.Migrations.AddFetchStateToFediversePostImages do
  @moduledoc """
  What a picture's download has tried so far (issue #1803).

  The fetch was fire-and-forget with nothing recording that it had failed, so a
  row whose bytes never arrived sat with a null `file` for ever and the card
  went on saying "picture is being checked" about a check that was never going
  to run. These two columns are what `Vutuv.Fediverse.MediaRefetcher` needs to
  find such a row, space its retries and eventually give up on it — and, once
  spent, they are also how `RemoteImage.unavailable?/1` knows to say so.

  **Additions only, and no backfill.** The rows already stuck carry everything
  the new code needs to read them: a null `moderation` beside a null `file` is
  the spelling the AI gate's rejection used before it learned to write
  `"rejected"`, and `unavailable?/1` reads it as one. Rewriting those four rows
  would buy nothing and would make `down/0` lossy, since by then it could no
  longer tell them from the refusals written after the deploy.

  One deploy is enough: the release still serving traffic neither reads nor
  writes either column, and its own view of these rows does not change.
  """
  use Ecto.Migration

  def change do
    alter table(:fediverse_post_images) do
      add(:fetch_failures, :integer, null: false, default: 0)
      add(:fetch_attempted_at, :utc_datetime)
    end

    # The sweeper's due query, in its own order: least recently tried first, and
    # among the never-tried the newest post first. Spelled out rather than left
    # to the column list, because btree defaults to NULLS LAST and the query
    # asks for NULLS FIRST — an index that can only filter still leaves the
    # whole file-less backlog to be sorted on every run.
    #
    # Partial, because a stored picture is the overwhelming majority of this
    # table and never takes part.
    create(
      index(:fediverse_post_images, ["fetch_attempted_at ASC NULLS FIRST", "id DESC"],
        where: "file IS NULL",
        name: :fediverse_post_images_fetch_due_index
      )
    )
  end
end
