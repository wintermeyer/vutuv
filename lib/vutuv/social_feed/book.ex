defmodule Vutuv.SocialFeed.Book do
  @moduledoc """
  The book a remote review is about, as the profile's "Book reviews" card shows
  it. Built by `Vutuv.Bookwyrm` and carried on the review's
  `Vutuv.SocialFeed.Post` (`post.book`).

  Everything except `title` is best-effort and may be nil: a review without
  stars has no `rating`, a review without its own title has no `headline`, and
  a book whose edition could not be fetched has neither `author` nor `cover`.
  The `cover` is fetched server-side and carried as a `data:` URI, like a feed
  avatar (`Vutuv.SocialFeed.Feed`), so a visitor's browser never contacts the
  remote instance.
  """

  defstruct [:title, :author, :rating, :headline, :cover]

  @type t :: %__MODULE__{
          title: String.t(),
          author: String.t() | nil,
          rating: float() | nil,
          headline: String.t() | nil,
          cover: String.t() | nil
        }
end
