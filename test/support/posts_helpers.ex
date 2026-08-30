defmodule Vutuv.PostsHelpers do
  @moduledoc false

  import Ecto.Query

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo
  alias Vutuv.ViewerClock

  @doc """
  Creates a post for `author`, unwrapping the `{:ok, post}` tuple so tests can
  use the struct directly.
  """
  def create_post!(author, attrs) do
    {:ok, post} = Posts.create_post(author, attrs)
    post
  end

  @doc """
  Moves `post` `seconds` into the past and hands back the updated struct.

  Every timestamp the feed compares has **second** precision, so a test whose
  posts, follows and spans all happen in one second is deciding ties rather than
  rules — anything asserting on order, on a cursor, or on a follow's span
  (issue #1673) has to place its posts by hand.
  """
  def backdate_post!(post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  @doc """
  Puts `post` **inside** `date`, the viewer's calendar day, `index` seconds
  before that day's midday — so a batch placed this way is ordered (index 1 the
  newest) and every member of it really is on the day the test then opens.

  Reach for this instead of `backdate_post!/2` whenever the test asserts on a
  **day**. "Three days and a bit more ago" subtracts the bit more from the
  current *time of day*, so a fixture spreading sixty posts over an hour walks
  the tail of that batch into the day before whenever the suite runs in the hour
  after the reader's midnight: green all day, red at 00:06, and read as a flake
  rather than as the arithmetic it is. Midday is the safe anchor, no offset a
  fixture plausibly spreads over reaches either edge of the day from there.

  The day is the **viewer's** (`Vutuv.ViewerClock.day_window/1`), the same clock
  the feed calendar counts and shades by, so the placement and the assertion
  cannot disagree about which day a post is on.

  For a **past** day, which is every caller so far. Asked for today it would
  place the post at a midday still to come, and a batch spread wider than the
  day is old cannot sit inside today at all — that is the calendar, not a
  defect, so pick a past day rather than working around it.
  """
  def place_post_on_day!(post, %Date{} = date, index \\ 0) do
    {day_start, _day_end} = ViewerClock.day_window(date)
    at = NaiveDateTime.add(day_start, 12 * 60 * 60 - index, :second)

    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [inserted_at: at])
    %{post | inserted_at: at}
  end

  @doc """
  The same for a reshare: `reposter`'s repost of `post`, moved `seconds` into
  the past. Repost order ties at second precision like everything else here, so
  any "newest resharer" assertion has to place its rows by hand.
  """
  def backdate_repost!(reposter, post, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -seconds)

    Repo.update_all(
      from(r in PostRepost, where: r.user_id == ^reposter.id and r.post_id == ^post.id),
      set: [inserted_at: at]
    )
  end

  @doc """
  A page's like on `post` (issue #1410), inserted directly — without the
  publisher-role and DNS-verification pipeline `Posts.like_post/3` sits behind.
  """
  def page_like!(post, page) do
    Repo.insert!(%PostLike{post_id: post.id, organization_id: page.id})
  end
end
