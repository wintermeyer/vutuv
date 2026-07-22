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

  **One notification per author per three hours, not one per entry.** Somebody
  filling in five roles in one sitting is one piece of news, so the feed groups
  an author's announced entries into three-hour buckets (`bucket_seconds/0`) and
  shows a single row that names them ("added 5 new entries to their CV"). The
  grouping is what the unread badge counts too, so a burst can never inflate it.

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

  # How long one "batch of CV news" lasts. Entries an author announces inside
  # the same three-hour wall-clock bucket share a single notification row.
  # Fixed buckets, not a sliding window: a bucket is a plain GROUP BY key, so
  # the items, the unread count and the read marker all derive from the same
  # cheap expression instead of needing per-reader state.
  @bucket_seconds 3 * 60 * 60

  # How many of a group's entries the notification names before it says
  # "and N more".
  @preview_entries 5

  @doc "The grouping window in seconds (three hours)."
  def bucket_seconds, do: @bucket_seconds

  # The bucket a timestamp falls into, as SQL. The window is baked into the
  # fragment **as a literal** rather than a query parameter on purpose:
  # Postgres matches a GROUP BY expression against the SELECT list
  # syntactically, and two placeholders ($1 here, $7 there) are not the same
  # expression — grouping by it then fails with "must appear in the GROUP BY
  # clause". A macro keeps the constant single-sourced anyway.
  defmacrop bucket_of_sql(field) do
    quote do
      fragment(
        unquote("floor(extract(epoch from ?) / #{@bucket_seconds})::bigint"),
        unquote(field)
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
  One notification group as the feed renders it: the group id, its newest
  timestamp, how many entries it holds and the newest few, named.

  Built for the live push (`announce/2`), where the just-saved `entry` fixes
  which bucket we are in; the reader-side twin is `page/3`, and both go through
  `group_item/4` so a pushed row and a reloaded page are the same row.
  """
  def group_payload(author_id, entry) do
    bucket = bucket_of(entry.inserted_at)

    rows =
      Repo.all(
        from(e in subquery(announced_entries()),
          where: e.user_id == ^author_id,
          where: bucket_of_sql(e.inserted_at) == ^bucket,
          order_by: [desc: e.inserted_at, desc: e.id],
          select: %{
            at: e.inserted_at,
            section: e.section,
            title: e.title,
            subtitle: e.subtitle,
            param: e.param
          }
        )
      )

    entries = Enum.map(rows, &Map.delete(&1, :at))
    group_item(author_id, bucket, latest_at(rows, entry.inserted_at), entries)
  end

  defp latest_at([%{at: at} | _], _fallback), do: at
  defp latest_at([], fallback), do: fallback

  @doc """
  One page of `recipient_id`'s CV update groups, newest first — the feed source
  `Vutuv.Activity` plugs into its cursor pagination.

  One query: the announced entries this reader may see, folded into
  `(author, three-hour bucket)` groups, each carrying its size and its entries'
  names as parallel arrays (same ORDER BY, so they zip). `cursor` filters on the
  group's newest entry, which is also what the row is timestamped and sorted by.
  """
  def page(recipient_id, limit, cursor) do
    recipient_id
    |> grouped_query(nil)
    |> select([e, _follow, author], %{
      user_id: e.user_id,
      bucket: bucket_of_sql(e.inserted_at),
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
    |> Enum.map(fn row ->
      entries =
        [row.sections, row.titles, row.subtitles, row.params]
        |> Enum.zip_with(fn [section, title, subtitle, param] ->
          %{section: section, title: title, subtitle: subtitle, param: param}
        end)

      row.user_id
      |> group_item(row.bucket, row.at, entries, row.count)
      |> Map.put(:author, row.author)
    end)
  end

  @doc """
  The reader's CV update **groups**, as a query `Vutuv.Activity` can count.
  `read_at` (nil = everything) keeps a group out unless its newest entry is
  newer than the read marker, so a burst counts as the single unread item it
  renders as.
  """
  def count_query(recipient_id, read_at) do
    recipient_id
    |> grouped_query(read_at)
    |> select([e], %{entries: count()})
  end

  # The shared grouped shape: the visible entries (feed_query/1), folded into
  # (author, bucket) groups. `read_at` filters on the group's newest entry —
  # a HAVING, not a WHERE, so an older entry never drags a fresh group out of
  # the unread count.
  defp grouped_query(recipient_id, read_at) do
    query =
      recipient_id
      |> feed_query()
      |> group_by([e, _follow, author], [
        e.user_id,
        author.id,
        bucket_of_sql(e.inserted_at)
      ])

    if read_at, do: having(query, [e], max(e.inserted_at) > ^read_at), else: query
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, %{at: at}), do: having(query, [e], max(e.inserted_at) <= ^at)

  # The one shape a CV update row has, wherever it comes from: a stable id
  # (author + bucket, so the live push updates the row the feed derives rather
  # than doubling it), the group's newest timestamp, the entries it names and
  # how many there are in total.
  defp group_item(author_id, bucket, at, entries, count \\ nil) do
    %{
      id: "cv-update-#{author_id}-#{bucket}",
      at: at,
      entry_count: count || length(entries),
      entries: Enum.take(entries, @preview_entries)
    }
  end

  defp bucket_of(%NaiveDateTime{} = at) do
    at
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
    |> div(@bucket_seconds)
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
