defmodule Vutuv.Profiles.CvUpdates do
  @moduledoc """
  CV update notifications (issue #980): "@greta added a new position to their
  CV".

  Three deliberate limits, all of them the point of the feature:

    * **CV only.** A new work experience, education entry or certificate /
      license — the three sections a Lebenslauf is made of. Nothing else on the
      profile announces itself.
    * **New entries only, author's choice.** The new-entry form carries one
      checkbox; `Vutuv.Profiles.CvSection.cast_announcement/2` only casts it on
      insert, so a later edit can never fire a second round. The LinkedIn
      import (and every other bulk path) leaves the column at its `false`
      default and stays silent.
    * **In-app only.** No email, ever. The reader's single opt-out is
      `users.cv_update_notifications?` on the notification settings page.

  **One notification per sitting, not one per entry.** Somebody filling in five
  roles in one go is one piece of news, so the feed groups an author's announced
  entries into *sittings*: entries less than `gap_seconds/0` (three hours) apart
  belong together, and a longer quiet stretch starts a new one. It is the
  gap-and-islands pattern, deliberately **not** a fixed three-hour raster — a
  raster would split 08:59 and 09:01 into two notifications while merging 09:01
  and 11:59 into one. A sitting is what the unread badge counts too, so a burst
  can never inflate it.

  Like every other kind in `Vutuv.Activity`, the feed is **derived at read
  time** — from the CV rows themselves, so nothing is duplicated: deleting the
  entry removes it from its group, and renaming the job renames it. `announce/2`
  only adds the live push that lights up an open session's bell; it carries the
  **whole group** under the group's own id, so a second entry updates that one
  row in place instead of stacking a new one.

  Who is told: everyone who followed the author **before** the entry appeared
  (a later follower is not backfilled with old news), minus muted follows and
  minus readers who switched the kind off. `feed_query/1` is that rule in one
  place; `Vutuv.Activity` reads items, counts and the read marker off it, and
  `announce/2` pushes to the same set, so live and derived can never disagree.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query, only: [account_hidden_row: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Moderation
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social.Follow

  # The quiet stretch that ends a sitting. Two announced entries closer together
  # than this belong to the same notification; a longer gap starts a new one.
  # Chosen at three hours: long enough to cover "I sat down and updated my CV"
  # including interruptions, short enough that yesterday's news never merges
  # into today's.
  @gap_seconds 3 * 60 * 60

  # How many of a group's entries the notification names before it says
  # "and N more".
  @preview_entries 5

  @doc "The quiet gap that ends a sitting, in seconds (three hours)."
  def gap_seconds, do: @gap_seconds

  # 1 when this entry starts a new sitting (no earlier entry by the same author,
  # or the previous one is more than the gap away), 0 when it continues the
  # current one. Running-summed below into a per-author sitting number.
  #
  # The gap is baked into the SQL **as a literal** rather than a query
  # parameter: a window expression repeated in an outer GROUP BY is matched
  # syntactically by Postgres, and two placeholders ($1 here, $7 there) are not
  # the same expression. The macro keeps the constant single-sourced anyway.
  defmacrop starts_sitting_sql do
    sql =
      "CASE WHEN ? - lag(?) OVER (PARTITION BY ? ORDER BY ?, ?) " <>
        "< interval '#{@gap_seconds} seconds' THEN 0 ELSE 1 END"

    quote do
      fragment(
        unquote(sql),
        e.inserted_at,
        e.inserted_at,
        e.user_id,
        e.inserted_at,
        e.id
      )
    end
  end

  # The running sitting number: how many sittings of this author have started
  # up to and including this entry. Every entry of one sitting shares it, which
  # makes it the GROUP BY key.
  defmacrop sitting_number_sql do
    quote do
      fragment(
        "sum(?) OVER (PARTITION BY ? ORDER BY ?, ? ROWS UNBOUNDED PRECEDING)",
        e.starts_sitting,
        e.user_id,
        e.inserted_at,
        e.id
      )
    end
  end

  @doc """
  Pushes the live "new CV entry" notification to the author's eligible
  followers. A no-op for an entry whose author did not tick the box, so the
  create actions can call it unconditionally.

  The payload is the author's **whole current bucket**, under that group's
  stable id, so a second entry within three hours updates the row an open
  session already shows rather than adding another one — the same row the feed
  would render on a reload.

  Runs inline: it is two indexed queries plus a local PubSub broadcast per
  follower, on a form a member submits a handful of times in their life.
  """
  def announce(author, entry)

  def announce(%User{} = author, %{announce_to_followers?: true} = entry) do
    if Moderation.account_hidden?(author) do
      :ok
    else
      payload = group_payload(author.id, entry)

      author.id
      |> recipient_ids()
      |> Enum.each(&Activity.notify_cv_update(&1, author, payload))
    end

    :ok
  end

  def announce(_author, _entry), do: :ok

  # The people an announcement reaches right now: they follow the author, they
  # have not muted them, and they have not switched the kind off. The same
  # three conditions feed_query/1 applies on the read side.
  defp recipient_ids(author_id) do
    Repo.all(
      from(f in Follow,
        join: u in User,
        on: u.id == f.follower_id,
        where: f.followee_id == ^author_id and not f.muted and u.cv_update_notifications?,
        select: f.follower_id
      )
    )
  end

  @doc """
  The sitting the just-saved `entry` belongs to, shaped exactly like a feed row
  — group id, newest timestamp, size and the newest few entries, named.

  Built for the live push (`announce/2`) from the **author's** own announced
  entries, through the same SQL the reader side uses (`sittings/1`), so a pushed
  row and a reloaded page are the same row. The one case they can differ: a
  reader who started following in the middle of an open sitting sees it cut
  short, so their derived row starts later than this one — they get a second row
  until the next load, which the reload then folds back into one.
  """
  def group_payload(author_id, _entry) do
    author_entries =
      from(e in subquery(announced_entries()), where: e.user_id == ^author_id)

    author_entries
    |> sittings()
    |> select([e], %{
      user_id: e.user_id,
      started_at: min(e.inserted_at),
      at: max(e.inserted_at),
      count: count(),
      sections: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.section, e.inserted_at, e.id),
      titles: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.title, e.inserted_at, e.id),
      subtitles:
        fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.subtitle, e.inserted_at, e.id),
      params: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.param, e.inserted_at, e.id)
    })
    |> order_by([e], desc: max(e.inserted_at))
    |> limit(1)
    |> Repo.one()
    |> to_group_item()
  end

  @doc """
  One page of `recipient_id`'s CV update sittings, newest first — the feed
  source `Vutuv.Activity` plugs into its cursor pagination.

  One query: the announced entries this reader may see, folded into sittings,
  each carrying its size and its entries' names as parallel arrays (same ORDER
  BY, so they zip). `cursor` filters on the sitting's newest entry, which is
  also what the row is timestamped and sorted by.
  """
  def page(recipient_id, limit, cursor) do
    recipient_id
    |> visible_entries()
    |> sittings()
    |> join(:inner, [e], author in User, on: author.id == e.user_id)
    |> group_by([_e, author], author.id)
    |> select([e, author], %{
      user_id: e.user_id,
      started_at: min(e.inserted_at),
      at: max(e.inserted_at),
      count: count(),
      author: struct(author, ^User.listing_fields()),
      sections: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.section, e.inserted_at, e.id),
      titles: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.title, e.inserted_at, e.id),
      subtitles:
        fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.subtitle, e.inserted_at, e.id),
      params: fragment("array_agg(? ORDER BY ? DESC, ? DESC)", e.param, e.inserted_at, e.id)
    })
    # The tiebreaker is the grouped author id (not an aggregate over the entry
    # ids): `max()` is not defined for uuid on every Postgres we support.
    |> order_by([e], desc: max(e.inserted_at), desc: e.user_id)
    |> limit(^limit)
    |> before_cursor(cursor)
    |> Repo.all()
    |> Enum.map(fn row -> row |> to_group_item() |> Map.put(:author, row.author) end)
  end

  @doc """
  The reader's CV update **sittings**, as a query `Vutuv.Activity` can count.
  `read_at` (nil = everything) keeps a sitting out unless its newest entry is
  newer than the read marker, so a burst counts as the single unread item it
  renders as.
  """
  def count_query(recipient_id, read_at) do
    query =
      recipient_id
      |> visible_entries()
      |> sittings()
      |> select([e], %{entries: count()})

    if read_at, do: having(query, [e], max(e.inserted_at) > ^read_at), else: query
  end

  # The reader's visible announced entries as plain columns — `feed_query/1`
  # minus its joins, the input the sitting window functions run over.
  defp visible_entries(recipient_id) do
    recipient_id
    |> feed_query()
    |> select([e], %{
      id: e.id,
      user_id: e.user_id,
      inserted_at: e.inserted_at,
      section: e.section,
      title: e.title,
      subtitle: e.subtitle,
      param: e.param
    })
  end

  # Gap and islands: number each author's entries by sitting (a running sum of
  # "this entry starts a new one"), then group by that number. Two nested
  # subqueries because a window function cannot be referenced in the same
  # SELECT that defines it, nor grouped by directly.
  defp sittings(entries) do
    numbered =
      from(e in subquery(entries),
        select: %{
          id: e.id,
          user_id: e.user_id,
          inserted_at: e.inserted_at,
          section: e.section,
          title: e.title,
          subtitle: e.subtitle,
          param: e.param,
          starts_sitting: starts_sitting_sql()
        }
      )

    sat =
      from(e in subquery(numbered),
        select: %{
          id: e.id,
          user_id: e.user_id,
          inserted_at: e.inserted_at,
          section: e.section,
          title: e.title,
          subtitle: e.subtitle,
          param: e.param,
          sitting: sitting_number_sql()
        }
      )

    from(e in subquery(sat), group_by: [e.user_id, e.sitting])
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, %{at: at}), do: having(query, [e], max(e.inserted_at) <= ^at)

  # One aggregated row -> the shape a CV update notification has everywhere.
  defp to_group_item(nil), do: nil

  defp to_group_item(row) do
    entries =
      [row.sections, row.titles, row.subtitles, row.params]
      |> Enum.zip_with(fn [section, title, subtitle, param] ->
        %{section: section, title: title, subtitle: subtitle, param: param}
      end)

    group_item(row.user_id, row.started_at, row.at, entries, row.count)
  end

  # The one shape a CV update row has, wherever it comes from. The id is the
  # author plus the sitting's **start**, so it stays the same while the sitting
  # grows: the live push then updates the row the feed derives instead of
  # doubling it (the start is what does not move; the newest timestamp does).
  defp group_item(author_id, started_at, at, entries, count) do
    %{
      id: "cv-update-#{author_id}-#{NaiveDateTime.diff(started_at, ~N[1970-01-01 00:00:00])}",
      at: at,
      entry_count: count,
      entries: Enum.take(entries, @preview_entries)
    }
  end

  @doc """
  Every announced CV entry `recipient_id` may see, as one query — the single
  source `Vutuv.Activity` derives its items, its unread count and its read
  marker from.

  The joins ARE the rule: the follow edge (unmuted, and older than the entry,
  so a new follower is not handed old news), the reader's own opt-out switch
  (an inner join that yields nothing once it is off), and the author's row,
  which both supplies the actor fields and drops a member moderation is
  hiding. The first binding is the entry, so `inserted_at` cursor and read
  marker filters compose onto it like every other feed source.
  """
  def feed_query(recipient_id) do
    from(entry in subquery(announced_entries()),
      join: follow in Follow,
      on:
        follow.followee_id == entry.user_id and follow.follower_id == ^recipient_id and
          not follow.muted,
      join: author in User,
      on: author.id == entry.user_id,
      join: reader in User,
      on: reader.id == ^recipient_id and reader.cv_update_notifications?,
      where: entry.inserted_at >= follow.inserted_at and not account_hidden_row(author)
    )
  end

  # The three CV sections as one uniform row shape, so everything downstream
  # (items, count, read marker) is a single query instead of three. `param` is
  # the entry's own route param, spelled the way each schema's Phoenix.Param
  # does it: the slug where there is one (a legacy import can carry NULL),
  # else the id.
  defp announced_entries do
    work = arm(WorkExperience, "work_experiences", :title, :organization, slug: true)
    education = arm(Education, "educations", :degree, :school, slug: true)
    qualification = arm(Qualification, "qualifications", :name, :issuer, slug: false)

    work |> union_all(^education) |> union_all(^qualification)
  end

  defp arm(schema, section, title_field, subtitle_field, slug: true) do
    from(e in schema,
      where: e.announce_to_followers?,
      select: %{
        id: e.id,
        user_id: e.user_id,
        inserted_at: e.inserted_at,
        section: type(^section, :string),
        title: field(e, ^title_field),
        subtitle: field(e, ^subtitle_field),
        param: fragment("COALESCE(NULLIF(?, ''), ?::text)", e.slug, e.id)
      }
    )
  end

  defp arm(schema, section, title_field, subtitle_field, slug: false) do
    from(e in schema,
      where: e.announce_to_followers?,
      select: %{
        id: e.id,
        user_id: e.user_id,
        inserted_at: e.inserted_at,
        section: type(^section, :string),
        title: field(e, ^title_field),
        subtitle: field(e, ^subtitle_field),
        param: fragment("?::text", e.id)
      }
    )
  end
end
