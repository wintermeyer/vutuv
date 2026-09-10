defmodule Vutuv.Repo.Migrations.CreateTagTrends do
  use Ecto.Migration

  # What is suddenly busy on the servers this installation reads from (issue
  # #2129), and the clock behind asking them.
  #
  # Both are plain additions and N-1 safe: the release now serving traffic
  # neither reads nor writes either table. Neither carries a `tag_id` — a
  # trending name is a stranger's word that may name no topic here at all — so
  # neither belongs in `Vutuv.Tags.Merge`'s `@movable`.
  def change do
    # The offer itself: one row per name, replaced wholesale by each pass, so a
    # reader never has to aggregate ten servers' answers to draw five pills.
    create table(:tag_trends) do
      # The remote spelling, as the server reporting the most uses writes it —
      # `hashtag_name/1` has already reduced it to what a `#hashtag` may hold.
      add(:name, :string, null: false)

      # Today's uses and the median of the six days before it, both summed over
      # the servers listing the tag. `:bigint` for the same reason the server
      # figures are: these are strangers' numbers and the column must not be the
      # reason a big day cannot be stored.
      add(:uses, :bigint, null: false)
      add(:baseline, :bigint, null: false)

      # The seven daily totals, newest first — what the pill's little chart
      # draws, and the evidence for "suddenly" rather than "a lot".
      add(:history, {:array, :bigint}, null: false)

      # How many servers list it. A pass asks every server it offers, so this
      # needs no second denominator: a tag only three of them name is a tag only
      # three of them name.
      add(:servers, :integer, null: false)

      # Those servers, most uses first: what a follow from this row names as its
      # sources, so following a busy tag actually brings something back.
      add(:hosts, {:array, :string}, null: false)

      # The vetting sample, kept because it is the whole defence against a bot
      # wave and an operator looking at a bad offer needs to see what was
      # measured: how many distinct author domains, how many bot accounts, out
      # of how many statuses.
      add(:author_hosts, :integer)
      add(:bot_posts, :integer)
      add(:sampled, :integer)

      add(:checked_at, :utc_datetime, null: false)

      timestamps()
    end

    create(unique_index(:tag_trends, [:name]))

    # The scheduler's clock, one row per server, stamped on **every** outcome
    # including the ones where nothing could be learned. A server that can never
    # be asked — the operator blocked it — must leave the due set anyway, or it
    # holds the front of every pass and the pass runs on every tick of the
    # two-minute loop instead of every half hour (issue #1316).
    create table(:tag_trend_servers) do
      add(:host, :string, null: false)
      add(:checked_at, :utc_datetime, null: false)
      add(:next_check_at, :utc_datetime, null: false)
      add(:last_outcome, :string)

      timestamps()
    end

    create(unique_index(:tag_trend_servers, [:host]))
  end
end
