defmodule Vutuv.Repo.Migrations.CreateExternalTagPosts do
  use Ecto.Migration

  # What a followed tag brings back from the servers it names (issue #2126):
  # the schedule of the pull, and the handful of posts it keeps.
  #
  # **Two tables of their own, and not `fediverse_posts`.** A row there is a
  # cached ActivityPub object and drags image ingestion, the AI image gate, the
  # screenshot queue and two counting sweepers behind it — none of which a REST
  # status read off a public tag timeline is, or should pay for. What is kept
  # here is text and a link, nothing else.
  #
  # Both are plain additions and the currently deployed release does not know
  # they exist, so this is N-1 safe and needs no second deploy.

  def change do
    # One row per (tag, server) pair anybody here wants, and the whole point of
    # it is the clock — see `Vutuv.Tags.ExternalFetch` for what the columns
    # promise and why a skip stamps them too.
    create table(:external_tag_fetches) do
      add(:tag_id, references(:tags, on_delete: :delete_all, type: :binary_id), null: false)

      # A bare lowercased hostname, never the local sentinel: this installation
      # is not a server we ask for our own posts.
      add(:source, :string, null: false)

      add(:checked_at, :utc_datetime, null: false)
      add(:next_fetch_at, :utc_datetime, null: false)
      add(:interval_seconds, :integer, null: false)
      add(:strikes, :integer, null: false, default: 0)

      # What the last pass did, for an operator reading the table.
      add(:last_outcome, :string)

      timestamps()
    end

    create(unique_index(:external_tag_fetches, [:tag_id, :source]))

    # The due query's own order: least-recently-due first, and a pair that has
    # never been fetched has no row here at all.
    create(index(:external_tag_fetches, [:next_fetch_at]))

    create table(:external_tag_posts) do
      add(:tag_id, references(:tags, on_delete: :delete_all, type: :binary_id), null: false)

      # The server the timeline was read from — which is not necessarily the
      # server the author is on.
      add(:source, :string, null: false)
      add(:remote_id, :string, null: false)

      # `:text` for both addresses, taking the type from the column they copy
      # (`fediverse_followers.inbox_uri`): a remote server's URLs are not ours
      # to bound, and a varchar(255) would raise 22001 on the fetch path where
      # no changeset of ours is watching.
      add(:url, :text, null: false)
      add(:author_url, :text)

      # Plain text, clamped by the client. Never HTML, never a picture.
      add(:text, :text, null: false)

      # `:text` too, and for the same reason, taking the type from the columns
      # they copy — `fediverse_followers.name` and `.handle`, text because a
      # remote display identity is not ours to bound either. They were
      # varchar(255) for one review round, which is a Postgres 22001 waiting on
      # the fetch path: `validate_length` counts **graphemes** and varchar
      # counts codepoints, so 100 ZWJ emoji pass a `max: 255` check as 100 and
      # arrive at the column as 700.
      add(:author_name, :text)
      add(:author_acct, :text)

      # Declared by the sending server, so knowing what language this is costs
      # no model call. Bounded, unlike a name, because it is a token rather than
      # somebody's chosen spelling of themselves — and the changeset caps it in
      # **bytes**, which in UTF-8 can never be fewer than the codepoints the
      # column counts.
      add(:language, :string)

      add(:published_at, :utc_datetime, null: false)

      timestamps()
    end

    # The same status arriving twice — two runs, or two tags on one post — is
    # one row per tag and source.
    create(unique_index(:external_tag_posts, [:tag_id, :source, :remote_id]))

    # The per-tag cap reads the newest rows of one tag; the hard ceiling reads
    # the newest rows overall.
    create(index(:external_tag_posts, [:tag_id, :published_at]))
    create(index(:external_tag_posts, [:published_at]))
  end
end
