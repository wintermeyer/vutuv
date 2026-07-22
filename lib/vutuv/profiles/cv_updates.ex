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

  Like every other kind in `Vutuv.Activity`, the feed is **derived at read
  time** — from the CV rows themselves, so nothing is duplicated: deleting the
  entry removes the notification, and renaming the job renames it. `announce/2`
  only adds the live push that lights up an open session's bell at the moment
  the entry is saved.

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

  @doc """
  Pushes the live "new CV entry" notification to the author's eligible
  followers. A no-op for an entry whose author did not tick the box, so the
  create actions can call it unconditionally.

  Runs inline: it is one indexed query plus a local PubSub broadcast per
  follower, on a page a member visits a handful of times in their life. The
  durable side needs nothing — the feed derives the same entry from the row
  that was just inserted.
  """
  def announce(author, entry)

  def announce(%User{} = author, %{announce_to_followers?: true} = entry) do
    if Moderation.account_hidden?(author) do
      :ok
    else
      payload = payload(entry)

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
  The notification payload for one CV entry: which section it belongs to, the
  route param its own page is reachable under, and the two lines that name it
  (`entry_title` leads, `entry_subtitle` qualifies — "Head of Bridges" at "Span
  AG"). The derived feed selects exactly these columns, so a pushed event and a
  reloaded page render identically.
  """
  def payload(%WorkExperience{} = entry) do
    %{
      section: "work_experiences",
      entry_param: Phoenix.Param.to_param(entry),
      entry_title: entry.title,
      entry_subtitle: entry.organization,
      at: entry.inserted_at
    }
  end

  def payload(%Education{} = entry) do
    %{
      section: "educations",
      entry_param: Phoenix.Param.to_param(entry),
      entry_title: entry.degree,
      entry_subtitle: entry.school,
      at: entry.inserted_at
    }
  end

  def payload(%Qualification{} = entry) do
    %{
      section: "qualifications",
      entry_param: Phoenix.Param.to_param(entry),
      entry_title: entry.name,
      entry_subtitle: entry.issuer,
      at: entry.inserted_at
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
