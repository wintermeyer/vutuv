defmodule Vutuv.Fediverse.PastFollow do
  @moduledoc """
  The span an ended follow of an account on another network was in force
  (issue #1673): `user_id` followed `remote_account_id` from `started_at` until
  `ended_at`.

  The twin of `Vutuv.Social.PastFollow`, whose moduledoc carries the shared
  half: the feed reads the *current* follow set, so unfollowing used to take
  the account's whole back catalogue with it, and a row here is what stays
  behind. Posts published and boosts announced inside the span keep showing;
  nothing after `ended_at` ever arrives. It records nothing for a **muted**
  follow (the mute already hid the past) and nothing for a **page's** follow,
  which is why the follower here is a member rather than the member-or-page
  pair `Vutuv.Fediverse.Follow` carries — only members have a feed.

  What is new on this side is a second job. A cached copy of a stranger's post
  is only held here because somebody follows its author, so
  `Vutuv.Fediverse.purge_unfollowed_remote_posts/1` deletes it the moment the
  last follower walks away — which would delete exactly the posts a span
  promises to keep. A span is therefore also a **hold** in `spare_held/1`, the
  fifth beside a reshare (#1166), a boost (#1167), a lookup (#1211) and a quote
  (#1609), buying what they buy: the right to live out the ordinary
  `expires_at` clock, never a day past it. And a member switching federation
  off or leaving takes their spans with them (`drop_remote_follows/1`) — they
  asked to be out of it, so a hold kept in their name is the opposite of the
  request.

  Written at the member-facing unfollow chokepoint
  (`Vutuv.Fediverse.unfollow_remote/2`) and nowhere else. Nothing here is a
  permission: a span shows only what the account published to an **open**
  audience (`Vutuv.Fediverse.RemotePost.open_audiences/0`), so a followers-only
  post drops out of the feed the moment the follow ends, span or no span.
  """

  use VutuvWeb, :model

  schema "fediverse_past_follows" do
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)
    # UTC rather than the naive stamps the local twin carries: these are
    # compared against `fediverse_posts.published_at` and
    # `fediverse_post_boosts.announced_at`, and every timestamp on this side of
    # the border is a `utc_datetime`.
    field(:started_at, :utc_datetime)
    field(:ended_at, :utc_datetime)

    timestamps()
  end

  @doc "A span from the follow that just ended."
  def changeset(model, params) do
    model
    |> cast(params, [:user_id, :remote_account_id, :started_at, :ended_at])
    |> validate_required([:user_id, :remote_account_id, :started_at, :ended_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:remote_account_id)
  end
end
