defmodule Vutuv.Landing do
  @moduledoc """
  The posts shown as examples under the logged-out landing page's sign-up form.

  What a profile looks like is answered on that page by static screenshots
  (`priv/static/images/landing-profile-*.webp`), which name nobody and cannot go
  stale in a way that embarrasses a member. The posts are the part that has to
  be live: their whole job is to show that this is a place with people in it
  today, and a screenshot of a timeline proves the opposite of that.

  They are drawn from the whole site, because a front page carrying one person's
  posts advertises that person rather than the network. The window is filled
  **round-robin**: everybody's best-liked post first, then
  everybody's second-best, and so on until the wall is full.

  That ordering rather than a flat "most liked" list or a hard one-per-member
  cap, because those two fail on opposite sides. A flat list lets whoever posts
  most take every slot. A hard cap of one leaves the wall half empty as soon as
  the site has fewer active members than it has slots — measured on the real
  data, a week holding 9 qualifying posts had **3** distinct authors, so
  one-per-member filled 3 of 8 cards and the pinboard read as a ghost town.
  Round-robin shows the most different faces the data allows *and* fills.

  Three filters stand between an ordinary post and the front page, and none of
  them is a human, so each has to earn its place. **At least `min_likes/0`
  likes**: nothing moderates the front door between a post landing and a
  stranger reading it, and "somebody already found this worth a heart" is the
  cheapest honest signal there is. **The author's own two opt-outs**
  (`noindex?` / `noai?`): a member who told us search engines and AI may not
  have their profile has said plainly enough that they are not looking for
  reach, and reading that as "and not the front page either" is the only fair
  reading. Plus `Posts.scope_visible/2` for the anonymous viewer, which drops
  restricted, frozen and hidden-author posts. **No replies**, for the reason
  the who-to-follow rail leaves them out too: an answer opens mid-conversation
  and says nothing to somebody who has never seen this site.

  Reads go through `Vutuv.Landing.Showcase`, a periodically refreshed ETS
  snapshot, because this is the most requested page in the app and it greets
  every crawler. When the snapshot cannot answer (boot, tests) this module runs
  the live query instead, so behaviour is identical, only more expensive.
  """
  import Ecto.Query

  alias Vutuv.Landing.Showcase
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  # A post needs this many hearts before it may stand on the front page.
  @min_likes 2
  # How far back the carousel reaches. A week, because the block's whole claim is
  # that the site is alive *now* — but a week that did not produce enough posts
  # would prove the opposite, so it falls back to four weeks rather than show a
  # near-empty row. The heading follows the window that was actually used
  # (`window_days/0`); a page that says "the past seven days" over four weeks of
  # posts is the one outcome worse than a short carousel.
  @window_days 7
  @fallback_window_days 28
  # Below this many cards the row reads as a ghost town, so the wider window is
  # tried instead. Cards, not posts: each post is rendered twice for the loop.
  @min_cards 10
  # How many posts the carousel deals. It renders each of them twice for the
  # marquee loop, so the page carries twice this many cards — 20 when the data
  # allows, fewer when it does not, which on a small installation is the normal
  # case rather than the exception.
  @post_limit 10
  # No member may hold more than this share of the carousel. One third, so at
  # least three different people are on it whenever three have posted at all.
  @max_author_share 3
  # How far the ranking looks before the per-member ceiling picks from it. Larger
  # than the carousel, because the ceiling drops posts as it walks: with the wall
  # itself as the limit, a member over their share would shorten the carousel
  # instead of letting the next member's post take the slot.
  @pool_limit 60

  @doc "How many likes a post needs before the landing page will show it."
  def min_likes, do: @min_likes

  @doc """
  How far back the shown posts actually reach, in days — the week, or the four
  weeks it fell back to. The heading reads this, so it can never claim a window
  the posts did not come from.
  """
  def window_days do
    case Showcase.read() do
      {:ok, %{window_days: days}} -> days
      :miss -> compute() |> Map.fetch!(:window_days)
    end
  end

  @doc "The window the carousel prefers, before any fallback."
  def preferred_window_days, do: @window_days

  @doc "The window it falls back to when the preferred one is too quiet."
  def fallback_window_days, do: @fallback_window_days

  @doc "How few cards count as too quiet."
  def min_cards, do: @min_cards

  @doc "How many posts the landing page shows at most."
  def post_limit, do: @post_limit

  @doc """
  How many of the wall's cards one member may hold at most.

  A ceiling of one third, so three different people are on the wall as soon as
  three have posted. It is what keeps a quiet week from handing the front page
  to whoever posts most: with the real data behind this (a week of 9 qualifying
  posts spread over 3 authors, one of them holding 7), an uncapped round-robin
  filled 6 of 8 cards with one person.

  The cost is a shorter wall while the site is quiet, and that is the right way
  round: a short wall of different faces says "small and alive", a full wall of
  one face says "one person talking to themselves".
  """
  def max_author_share, do: @max_author_share

  @doc "The per-member ceiling in cards, derived from `max_author_share/0`."
  def max_per_author, do: max(1, ceil(@post_limit / @max_author_share))

  @doc """
  The posts shown as examples: the window filled round-robin (everybody's
  best-liked post, then everybody's second), preloaded for the post card.
  """
  def showcase_posts do
    case Showcase.read() do
      {:ok, %{posts: posts}} -> posts
      :miss -> compute() |> Map.fetch!(:posts)
    end
  end

  @doc """
  Recompute the list. Called by `Vutuv.Landing.Showcase` on its refresh timer,
  and by `showcase_posts/0` whenever the snapshot is cold.
  """
  def compute do
    case deal(@window_days) do
      # A week too quiet to fill the row: widen rather than show a stub. Checked
      # on the CARDS, since that is what somebody looking at the page counts.
      %{posts: posts} = week when length(posts) * 2 < @min_cards ->
        wider = deal(@fallback_window_days)

        # Only if the wider window actually helps — on a brand-new installation
        # it finds the same nothing, and then the honest heading is the week.
        if length(wider.posts) > length(posts), do: wider, else: week

      week ->
        week
    end
  end

  defp deal(days) do
    pool = compute_pool(days)

    %{
      pool: pool,
      posts: pool |> take_capped() |> Enum.map(& &1.id) |> load_in_order(),
      window_days: days
    }
  end

  # Fills up to `post_limit/0` while no member exceeds `max_per_author/0`. One
  # walk of the ranked pool, so the round-robin order decides who gets in and the
  # ceiling only ever skips — which is why the pool has to be longer than the
  # carousel: a skipped post must leave its slot to the next member, not shorten
  # the row.
  defp take_capped(entries) do
    entries
    |> Enum.reduce({[], %{}}, fn entry, {taken, counts} ->
      held = Map.get(counts, entry.user_id, 0)

      if length(taken) < @post_limit and held < max_per_author() do
        {[entry | taken], Map.put(counts, entry.user_id, held + 1)}
      else
        {taken, counts}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Two steps rather than one: rank cheaply over ids and like counts, then load
  # only the handful that will be shown, with the card's full preloads.
  # Preloading first would drag every candidate's images, tags and review
  # sidecar through the ranking — and the pool is many times the wall.
  defp compute_pool(days) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -days, :day)

    candidates =
      from(p in Post, as: :post)
      |> join(:inner, [post: p], u in assoc(p, :user), as: :author)
      # Both kinds of answer, because a post is a reply through EITHER sidecar:
      # `reply_ref` for an answer to a post here, `remote_reply_ref` for an
      # answer to something from another network. Filtering only the first one
      # put a "Replying to @droidboy@social.cologne" card on the landing page,
      # which opens mid-conversation and reads as half a sentence to somebody
      # who has never seen this site.
      |> join(:left, [post: p], r in assoc(p, :reply_ref), as: :reply_ref)
      |> join(:left, [post: p], rr in assoc(p, :remote_reply_ref), as: :remote_reply_ref)
      |> where([post: p], p.body != "" and p.inserted_at >= ^cutoff)
      |> where([reply_ref: r, remote_reply_ref: rr], is_nil(r.id) and is_nil(rr.id))
      # The author's own reach opt-outs, read as covering the front page too.
      |> where([author: u], u.email_confirmed? and not u.noindex? and not u.noai?)
      # The anonymous view, because that is who reads the landing page: drops
      # restricted, frozen and hidden-author posts.
      |> Posts.scope_visible(nil)
      |> select([post: p], %{
        id: p.id,
        user_id: p.user_id,
        # One like figure per post: vutuv's own hearts plus the favourites other
        # networks sent, the same folding `Posts.shown_counts/1` does for the
        # card, so the bar means the same thing as the heart under the post.
        likes:
          fragment(
            """
            (SELECT count(*) FROM post_likes l WHERE l.post_id = ?)
            + (SELECT count(*) FROM fediverse_reactions fr
                 WHERE fr.post_id = ? AND fr.kind = 'like')
            """,
            p.id,
            p.id
          )
      })

    # Each member's posts numbered best-first. Ids are UUID v7, so `desc: id`
    # breaks a tie in favour of the newer post.
    ranked =
      from(c in subquery(candidates),
        where: c.likes >= ^@min_likes,
        select: %{
          id: c.id,
          user_id: c.user_id,
          likes: c.likes,
          rank: over(row_number(), partition_by: c.user_id, order_by: [desc: c.likes, desc: c.id])
        }
      )

    # Round-robin order: `rank` first, so every member's best post comes before
    # anybody's second. Deliberately **not** capped here — the cap belongs to
    # what is dealt onto the wall (`take_capped/1`), not to the pool, or the
    # shuffle would have nothing left to draw from on a quiet installation.
    from(r in subquery(ranked),
      order_by: [asc: r.rank, desc: r.likes, desc: r.id],
      limit: ^@pool_limit,
      select: %{id: r.id, user_id: r.user_id, likes: r.likes}
    )
    |> Repo.all()
  end

  defp load_in_order(ids) do
    by_id =
      from(p in Post, where: p.id in ^ids)
      |> Repo.all()
      |> Repo.preload(Posts.render_preloads())
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
  end
end
