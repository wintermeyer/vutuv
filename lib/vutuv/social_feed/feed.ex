defmodule Vutuv.SocialFeed.Feed do
  @moduledoc """
  A fetched remote social feed as the profile shows it: the account's display
  name, profile URL and avatar, plus the latest posts. Built exclusively by
  the provider clients' `fetch_posts/1` (`Vutuv.Mastodon`, `Vutuv.Bluesky`).

  The avatar is fetched **server-side** and carried as a `data:` URI (or nil
  when the network offers none / it fails the guards), so a visitor's browser
  never contacts the remote network — the same privacy stance that keeps
  post media out of the feed.
  """

  defstruct [:name, :handle, :url, :avatar, posts: []]

  @type t :: %__MODULE__{
          name: String.t(),
          handle: String.t(),
          url: String.t(),
          avatar: String.t() | nil,
          posts: [Vutuv.SocialFeed.Post.t()]
        }
end
