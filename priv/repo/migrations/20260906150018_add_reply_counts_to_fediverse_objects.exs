defmodule Vutuv.Repo.Migrations.AddReplyCountsToFediverseObjects do
  use Ecto.Migration

  # How many people answered an object out there, and the index that lets us
  # show those answers.
  #
  # The sibling of the like and repost figures beside it, with one difference
  # that decides the whole design: `likes` and `shares` arrive as a
  # `totalItems` in the object itself, `replies` does not. Forty objects from
  # our own cache were asked before this was written and **not one** of their
  # servers served a `totalItems` on that collection — Mastodon serialises
  # `replies` as a Collection whose first page carries the author's own
  # follow-ups and whose second (`only_other_accounts=true`) carries everybody
  # else's, 60 ids to a page and no total anywhere. So the figure is counted,
  # not read, and counting costs a request of its own. That is why this gets its
  # own clock instead of riding `counts_checked_at`: the ask happens on a much
  # flatter ladder than the one the two cheap figures run on.
  #
  # Nullable for the same reason as those two: `replies` is MAY in ActivityPub
  # §5.7, flipboard.com (19 % of everything we cache) serves none of the three,
  # and "we have not been told" must stay distinguishable from "nobody
  # answered". A zero is a claim, and not ours to make for somebody else.
  #
  # All plain additions, so N-1 compatible: the release currently serving
  # traffic never reads them.
  def change do
    for table <- [:fediverse_posts, :fediverse_notes] do
      alter table(table) do
        add(:replies_count, :integer)
        add(:replies_checked_at, :utc_datetime)
        # Consecutive failed asks, driving the same doubling backoff the like
        # figures use, so a server having a bad day stops seeing us.
        add(:replies_failures, :integer, null: false, default: 0)
      end

      # No index on `replies_checked_at`: nothing queries it. The count rides
      # the like ask, which has already selected its object, so due-ness is
      # decided in Elixir on a row in hand — an index here would be written on
      # every stamp and read by nobody.

      # The origin serves none of these collections, so there is nothing here to
      # ask about ever again. Not a failure — the server answered, correctly,
      # with a document that simply carries no figures — and therefore not a
      # strike: the backoff exists for servers having a bad day, this is a
      # property of the software.
      #
      # It earns its column by what it costs not to have it. On a copy of
      # production, flipboard.com held 1.026 of the 2.627 objects on the ladder
      # (39 %) and had answered 0 of its 1.478 stored posts with a figure of any
      # kind; the ladder was so far behind that 2.511 of those 2.627 objects
      # were overdue, the median one asked at 1,9 times its own interval and the
      # p90 at ten times. A five-minute tier that is really reached every 87
      # minutes is not a ladder, and this is what pays for the reply figure
      # above without asking anybody for more traffic.
      alter table(table) do
        add(:counts_absent, :boolean, null: false, default: false)
      end

      # And the ladder's own index narrowed to the rows it still serves.
      # Filtering absent rows out of the query is not enough on its own: they
      # are never stamped again, so they keep the oldest `counts_checked_at`
      # values there are and sit permanently at the head of an
      # `asc_nulls_first` scan the planner then has to walk past — 1.026 of
      # 2.627 rows, on every run, forever. A partial index is where they stop
      # existing for this query at all.
      create(
        index(table, [:counts_checked_at],
          where: "counts_absent = false",
          name: :"#{table}_counts_due_index"
        )
      )
    end

    # An answer we fetched **because somebody opened a thread**, rather than
    # because anybody here follows its author. It is a cached post in every
    # other respect (card, action bar, report, retention), and this column is
    # what keeps it out of the surfaces that list an account's posts.
    #
    # Without it the feature would quietly rewrite people's feeds: a delivered
    # reply is only ever stored when it continues a thread of the **same**
    # account (`own_thread?/2`), so an answer by somebody a member follows has
    # never been feed material here. Fetching one as thread context would drop
    # it into that member's feed at its own old timestamp, days back, with
    # nobody having asked for it.
    alter table(:fediverse_posts) do
      add(:thread_context, :boolean, null: false, default: false)
    end

    # The answers themselves are cached posts like any other (a reply *is* a
    # post, and storing it as one is what gives it a card, an action bar, a
    # report path and a retention clock for free). Reading them back means
    # asking for every cached post that answers this one, which is a column
    # nothing indexed before — every other reader of `in_reply_to_uri` had a
    # single row in hand. Partial: only a reply carries the column at all, and
    # most cached posts are not replies.
    create(
      index(:fediverse_posts, [:in_reply_to_uri],
        where: "in_reply_to_uri IS NOT NULL",
        name: :fediverse_posts_in_reply_to_uri_index
      )
    )
  end
end
