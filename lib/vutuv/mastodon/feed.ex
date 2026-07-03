defmodule Vutuv.Mastodon.Feed do
  @moduledoc """
  A fetched Mastodon feed as the profile shows it: the account's display name,
  profile URL and avatar, plus the latest posts. Built exclusively by
  `Vutuv.Mastodon.fetch_posts/1`.

  The avatar is fetched **server-side** and carried as a `data:` URI (or nil
  when the instance offers none / it fails the guards), so a visitor's browser
  never contacts the federated instance — the same privacy stance that keeps
  post media out of the feed.
  """

  defstruct [:name, :handle, :url, :avatar, posts: []]

  @type t :: %__MODULE__{
          name: String.t(),
          handle: String.t(),
          url: String.t(),
          avatar: String.t() | nil,
          posts: [Vutuv.Mastodon.Post.t()]
        }
end
