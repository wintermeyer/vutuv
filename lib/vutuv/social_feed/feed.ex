defmodule Vutuv.SocialFeed.Feed do
  @moduledoc """
  A fetched remote social feed as the profile shows it: the account's display
  name, profile URL and avatar, plus the latest posts. Built exclusively by
  the provider clients' `fetch_posts/1` (`Vutuv.Mastodon`, `Vutuv.Bluesky`).

  The avatar is fetched **server-side** and carried as a `data:` URI (or nil
  when the network offers none / it fails the guards), so a visitor's browser
  never contacts the remote network — the same privacy stance that keeps
  post media out of the feed.

  `followers` is the account's follower count as the remote network reports it.
  Both clients read it out of the account call they already make (Bluesky's
  `app.bsky.actor.getProfile`, Mastodon's `/api/v1/accounts/lookup`), so it
  costs no extra request. It is `nil` whenever the network offers no usable
  number — a sparse answer must render as nothing, never as a misleading `0`.
  """

  defstruct [:name, :handle, :url, :avatar, :followers, posts: []]

  @type t :: %__MODULE__{
          name: String.t(),
          handle: String.t(),
          url: String.t(),
          avatar: String.t() | nil,
          followers: non_neg_integer() | nil,
          posts: [Vutuv.SocialFeed.Post.t()]
        }

  @doc """
  The `followers` value for a count as it arrived in the remote JSON: the
  integer itself, or `nil` for anything else. Shared by both clients so a
  sparse or malformed answer degrades the same way on either network — the
  card then shows no count at all, rather than a `0` that reads as a fact.
  """
  def follower_count(count) when is_integer(count) and count >= 0, do: count
  def follower_count(_count), do: nil
end
