defmodule Vutuv.Posts.AutoDeletion do
  @moduledoc """
  Automatic deletion of a member's own posts once they pass an age the member
  set (issue #1255), configured on /settings/auto_post_deletion.

  Off for everybody until they turn it on. Nothing about it is an installation
  default: it is not a `Vutuv.Prefs` knob precisely because prefs fall back to
  an admin-set value, and no admin may set a default that deletes somebody
  else's posts.

  ## One query, two callers

  `due_query/1` is the whole rule, and both callers go through it: the
  confirmation dialog on the settings page counts with `count_due/1`, the
  nightly pass deletes with `run_for/2`. That is not tidiness — the dialog
  tells the member a number and then deletes, so a second, separately written
  query would eventually make that number a lie.

  ## What the rule never touches

  Three things are kept whatever the member ticks, because a checkbox for them
  would only be a way to lose something you cannot get back:

    * the **pinned post** — it is the one post the member deliberately put at
      the top of their profile;
    * a **frozen** post or one with an **open moderation case** — it is the
      evidence in a complaint somebody else filed, and it is already invisible;
    * anything **newer than the threshold**, obviously.

  ## The Fediverse half

  Deletion runs through `Vutuv.Posts.delete_post/1`, the one path that also
  drops the photo files, empties open clients' action bars and asks other
  servers to delete their copy (`Delete(Tombstone)`). "Asks" is the honest
  word: a remote server that is offline, that has defederated or that simply
  ignores the activity keeps what it has, and copies people made by hand are
  out of reach entirely. The settings page says so in as many words.

  ## Scheduling

  `Vutuv.Posts.AutoDeletionSweeper` runs one pass per member per Berlin day.
  `auto_post_deletion_swept_on` is stamped on **every** pass, including the
  ones that delete nothing: it is the scheduler's clock, not a claim that work
  happened, and a member the sweeper can do nothing for must not hold the
  front of the oldest-first batch forever.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.AccountEvents
  alias Vutuv.Accounts.User
  alias Vutuv.BerlinTime
  alias Vutuv.Moderation.Case
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostBookmark
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.Repo

  # How many posts one nightly pass deletes for one member. A ceiling rather
  # than a target: a member who enabled the rule on ten years of posting gets
  # the backlog spread over a few nights instead of one pass holding a
  # connection for minutes and firing thousands of federation deliveries in a
  # burst. Whatever is left is due again tomorrow. The member's own confirmed
  # run on the settings page is NOT capped — they were shown an exact number
  # and pressed the button for it.
  @per_pass_limit 500

  # How many members one nightly pass walks, least-recently-swept first.
  @members_per_pass 1_000

  @doc """
  Whether `user`'s rule is complete enough to run: switched on **and** carrying
  an age. The changeset already refuses one without the other; this is the
  belt-and-braces read, so a row that predates the validation (or a hand-made
  update) can never be read as "delete everything".
  """
  def active?(%User{auto_post_deletion?: true, auto_post_deletion_after_days: days})
      when is_integer(days) and days > 0,
      do: true

  def active?(%User{}), do: false

  @doc """
  The posts `user`'s rule would delete right now, oldest first.

  Ordered oldest-first so a capped pass always takes the posts that have been
  due longest, and so a member watching the count shrink sees it work from the
  far end of their archive.
  """
  def due_query(%User{} = user) do
    from(p in Post, as: :post)
    |> where([p], p.user_id == ^user.id)
    |> where([p], p.inserted_at < ^cutoff(user))
    |> where([p], is_nil(p.frozen_at))
    |> exclude_pinned(user)
    |> exclude_under_moderation()
    |> exclude_replies(user)
    |> exclude_photos(user)
    |> exclude_answered(user)
    |> exclude_bookmarked(user)
    |> exclude_by_likes(user)
    |> exclude_by_bookmarks(user)
    |> exclude_by_reposts(user)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
  end

  @doc """
  How many posts `user`'s rule would delete right now. The number the
  confirmation dialog shows. Zero for a member whose rule is not active, so
  the caller never has to ask twice.
  """
  def count_due(%User{} = user) do
    if active?(user) do
      user |> due_query() |> exclude(:order_by) |> Repo.aggregate(:count)
    else
      0
    end
  end

  @doc """
  Deletes what `user`'s rule is due to delete and stamps the sweeper clock.

  Options:

    * `:limit` — how many posts at most, `@per_pass_limit` by default. Pass
      `:infinity` for the member's own confirmed run on the settings page.
    * `:today` — the Berlin day to stamp (the sweeper passes the day it is
      working on).

  Returns `{:ok, count}` with the number of posts deleted; an inactive rule is
  `{:ok, 0}` and still stamps the clock, because "nothing to do for this
  member" is exactly the outcome the clock has to advance past.
  """
  def run_for(%User{} = user, opts \\ []) do
    today = Keyword.get(opts, :today, BerlinTime.today())
    limit = Keyword.get(opts, :limit, @per_pass_limit)

    deleted = if active?(user), do: delete_due(user, limit), else: 0

    stamp(user, today)
    if deleted > 0, do: record_deletion(user, deleted)

    {:ok, deleted}
  end

  @doc """
  The members due for a pass on `today`: switched on, not yet swept today,
  least recently swept first (a member who has never been swept comes first of
  all).
  """
  def due_users(today \\ BerlinTime.today(), limit \\ @members_per_pass) do
    from(u in User,
      where: u.auto_post_deletion? == true,
      where: is_nil(u.auto_post_deletion_swept_on) or u.auto_post_deletion_swept_on < ^today,
      order_by: [asc_nulls_first: u.auto_post_deletion_swept_on, asc: u.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  One nightly pass: every due member, capped at `@members_per_pass`. Returns
  the total number of posts deleted.

  A pass that hits the member cap says so in the log rather than looking like
  it finished the queue — the rest are simply first in line tomorrow.
  """
  def sweep(today \\ BerlinTime.today()) do
    members = due_users(today)

    deleted =
      Enum.reduce(members, 0, fn user, total ->
        {:ok, count} = run_for(user, today: today)
        total + count
      end)

    if length(members) >= @members_per_pass do
      Logger.info(
        "AutoDeletion swept #{@members_per_pass} members (the per-pass cap); more are due tomorrow"
      )
    end

    if deleted > 0 do
      Logger.info("AutoDeletion deleted #{deleted} post(s) for #{length(members)} member(s)")
    end

    deleted
  end

  @doc "The per-pass post ceiling, so tests and the settings page can name it."
  def per_pass_limit, do: @per_pass_limit

  # ── The rule ──

  # The instant a post has to predate. Days, from the member's own list.
  defp cutoff(%User{auto_post_deletion_after_days: days}) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-days * 24 * 60 * 60, :second)
    |> NaiveDateTime.truncate(:second)
  end

  defp exclude_pinned(query, %User{pinned_post_id: nil}), do: query

  defp exclude_pinned(query, %User{pinned_post_id: pinned_id}),
    do: where(query, [p], p.id != ^pinned_id)

  # Reported content belongs to the complaint, not only to its author: while a
  # case is open the post is the evidence in it, and a frozen post is already
  # invisible to everyone but its author and the admins.
  defp exclude_under_moderation(query) do
    where(
      query,
      not exists(
        from(c in Case,
          where: c.content_type == "post",
          where: c.content_id == parent_as(:post).id,
          where: c.status in ^Case.open_statuses(),
          select: 1
        )
      )
    )
  end

  # The member's own replies in other people's threads. Off by default: a reply
  # is one turn in a conversation somebody else is still reading.
  defp exclude_replies(query, %User{auto_post_deletion_delete_replies?: true}), do: query

  defp exclude_replies(query, %User{}) do
    where(
      query,
      not exists(from(r in PostReply, where: r.post_id == parent_as(:post).id, select: 1))
    )
  end

  # Photos and book/film reviews: the posts that took work, and the ones whose
  # files are gone for good with them.
  defp exclude_photos(query, %User{auto_post_deletion_keep_photos?: false}), do: query

  defp exclude_photos(query, %User{}) do
    query
    |> where(not exists(from(i in PostImage, where: i.post_id == parent_as(:post).id, select: 1)))
    |> where(
      not exists(from(r in PostReview, where: r.post_id == parent_as(:post).id, select: 1))
    )
  end

  # A post somebody answered is the root of a conversation. Deleting it does
  # not delete the replies (they survive and re-anchor), it guts the thread
  # they live in — which is why this counts **any** reply, from vutuv or from
  # another network, and counts the ones addressed to the member alone too:
  # the question is "did this post start something", not "how many can a
  # stranger see".
  defp exclude_answered(query, %User{auto_post_deletion_keep_answered?: false}), do: query

  defp exclude_answered(query, %User{}) do
    query
    |> where(
      not exists(from(r in PostReply, where: r.parent_post_id == parent_as(:post).id, select: 1))
    )
    |> where(
      [p],
      fragment("NOT EXISTS (SELECT 1 FROM fediverse_notes fn WHERE fn.post_id = ?)", p.id)
    )
  end

  # The per-post escape hatch: bookmark your own post and the rule steps over
  # it. Deliberately the member's OWN bookmark — somebody else's says nothing
  # about what the author wants kept (that is what the count floor below is
  # for).
  defp exclude_bookmarked(query, %User{auto_post_deletion_keep_bookmarked?: false}), do: query

  defp exclude_bookmarked(query, %User{id: user_id}) do
    where(
      query,
      not exists(
        from(b in PostBookmark,
          where: b.post_id == parent_as(:post).id,
          where: b.user_id == ^user_id,
          select: 1
        )
      )
    )
  end

  # The engagement floors. Each keeps a post whose count has REACHED the floor,
  # so the query deletes only what is strictly below it, and a floor of 0 is
  # off (nothing can be below zero).
  #
  # Likes and reposts count what other networks did as well, because that is
  # the figure the member is shown on their own post (`Posts.shown_counts/1`);
  # counting only vutuv's half would mean a post the member sees as "12 Likes"
  # is deleted by a floor of 10. Bookmarks are local by nature: a bookmark is
  # private to whoever made it and no server sends one on.
  defp exclude_by_likes(query, %User{auto_post_deletion_min_likes: min}) when min > 0 do
    where(
      query,
      [p],
      fragment(
        """
        ((SELECT count(*) FROM post_likes l WHERE l.post_id = ?)
          + (SELECT count(*) FROM fediverse_reactions fr
              WHERE fr.post_id = ? AND fr.kind = 'like')) < ?
        """,
        p.id,
        p.id,
        ^min
      )
    )
  end

  defp exclude_by_likes(query, %User{}), do: query

  defp exclude_by_bookmarks(query, %User{auto_post_deletion_min_bookmarks: min}) when min > 0 do
    where(
      query,
      [p],
      fragment("(SELECT count(*) FROM post_bookmarks b WHERE b.post_id = ?) < ?", p.id, ^min)
    )
  end

  defp exclude_by_bookmarks(query, %User{}), do: query

  defp exclude_by_reposts(query, %User{auto_post_deletion_min_reposts: min}) when min > 0 do
    where(
      query,
      [p],
      fragment(
        """
        ((SELECT count(*) FROM post_reposts r WHERE r.post_id = ?)
          + (SELECT count(*) FROM fediverse_reactions fr
              WHERE fr.post_id = ? AND fr.kind = 'announce')) < ?
        """,
        p.id,
        p.id,
        ^min
      )
    )
  end

  defp exclude_by_reposts(query, %User{}), do: query

  # ── Doing it ──

  defp delete_due(user, limit) do
    user
    |> due_query()
    |> maybe_limit(limit)
    |> Repo.all()
    |> Enum.count(&deleted?/1)
  end

  defp maybe_limit(query, :infinity), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  # One failed delete must not abort the pass: the next post in the list is
  # unrelated, and a member whose rule silently stopped at the first hiccup
  # would keep posts they asked to have gone.
  defp deleted?(post) do
    case Posts.delete_post(post) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.error("AutoDeletion could not delete post #{post.id}: #{inspect(reason)}")
        false
    end
  end

  # The scheduler's clock. Written straight, not through a changeset: it is not
  # a member-facing field and nothing about it is castable.
  defp stamp(%User{id: user_id}, today) do
    Repo.update_all(
      from(u in User, where: u.id == ^user_id),
      set: [auto_post_deletion_swept_on: today]
    )

    :ok
  end

  # One line in the member's own account activity log (issue #1087) per pass
  # that deleted something, so the deletions are never something that merely
  # happened to their account without a trace. The count is the whole detail:
  # which posts they were is exactly what is gone.
  defp record_deletion(user, count) do
    AccountEvents.record(user, "posts_auto_deleted", details: %{count: count})
  end
end
