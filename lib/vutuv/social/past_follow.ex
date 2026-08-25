defmodule Vutuv.Social.PastFollow do
  @moduledoc """
  The span an ended follow was in force (issue #1673): `follower_id` followed
  `followee_id` (or `followee_organization_id`) from `started_at` until
  `ended_at`.

  A follow is what puts somebody's posts in your feed, and the feed reads the
  *current* follow set — so unfollowing used to take the followee's whole back
  catalogue with it, including the posts that had already reached the reader.
  A row here is what stays behind: the posts published inside the span keep
  showing, nothing published after `ended_at` ever arrives.

  Written at the two member-facing unfollow chokepoints
  (`Vutuv.Social.unfollow!/2` and `unfollow_organization/2`) and nowhere else.
  Two deliberate silences:

    * **A muted follow records no span.** Muting already means "their posts
      leave my feed", retroactively — recording a span at the unfollow would
      hand back exactly what the mute was hiding.
    * **A severed follow records no span** (`Vutuv.Social.sever_between/2`),
      which also deletes any span the pair already had. A block clears the past
      too, and unblocking restores nothing.

  Nothing here is a permission: `Vutuv.Posts.scope_visible/2` still runs over
  every feed row, so a followers-only post drops out of the feed the moment the
  follow ends, span or no span.
  """

  use VutuvWeb, :model

  schema "past_follows" do
    belongs_to(:follower, Vutuv.Accounts.User)
    # A member or a page, exactly one, CHECK-enforced — the same nullable pair
    # `Vutuv.Social.Follow` carries on its followee side. The follower stays a
    # member: only members have a feed for a span to feed.
    belongs_to(:followee, Vutuv.Accounts.User)
    belongs_to(:followee_organization, Vutuv.Organizations.Organization)
    field(:started_at, :naive_datetime)
    field(:ended_at, :naive_datetime)

    timestamps()
  end

  @doc """
  A span from the follow that just ended. `followee` names the column the target
  sits in, so one changeset covers both spellings and neither can be forgotten:
  `validate_required/2` asks for the one that was named.
  """
  def changeset(model, followee, params \\ %{})
      when followee in [:followee_id, :followee_organization_id] do
    model
    |> cast(params, [:follower_id, followee, :started_at, :ended_at])
    |> validate_required([:follower_id, followee, :started_at, :ended_at])
    |> foreign_key_constraint(:follower_id)
    |> foreign_key_constraint(followee)
    |> check_constraint(:followee_id, name: :past_follows_exactly_one_followee)
  end
end
