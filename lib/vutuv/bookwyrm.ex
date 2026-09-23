defmodule Vutuv.Bookwyrm do
  @moduledoc """
  The BookWyrm client of the inline social feeds (`Vutuv.SocialFeed`): fetches
  a member's latest public book reviews for the profile's "Book reviews" card.

  BookWyrm speaks ActivityPub but offers no Mastodon-compatible REST API, so
  this reads the member's public outbox (`Vutuv.SocialFeed.ActivityPub`). Only
  the reviews are kept (an `Article` with an `inReplyToBook`); the reading-status
  notes and comments beside them are not. Each review's book is looked up for
  its title, first author and cover, and any of those failing leaves the
  review standing with less detail rather than dropping it.

  Like `Vutuv.Mastodon` it never runs in a request or LiveView process
  (`Vutuv.SocialFeed.Cache` owns the fetch tasks), and the remote `content`
  is reduced to plain text here and HEEx-escaped at render time — never
  render any of it with `raw/1`.
  """

  require Logger

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse
  alias Vutuv.SocialFeed.ActivityPub
  alias Vutuv.SocialFeed.Book
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  @reviews_shown 3

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :bookwyrm_req_options

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests):
  `{:ok, %Feed{}}` whose posts are the reviews, each with its `book`, or a
  classified `{:error, :gone | :transient}` like every feed client.
  """
  def fetch_posts(handle) do
    with {:ok, actor, _links} <- ActivityPub.resolve(handle, @req_options),
         {:ok, items} <- ActivityPub.outbox_items(actor, @req_options) do
      {:ok,
       %Feed{
         name: ActivityPub.display_name(actor, handle),
         handle: handle,
         url: actor["id"],
         posts: reviews(items, actor["id"])
       }}
    end
  rescue
    error ->
      Logger.warning("bookwyrm fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  # The books are looked up side by side: each one costs up to three requests
  # (edition, author, cover), and the profile's spinner waits for all of them.
  defp reviews(items, actor_id) do
    items
    |> Enum.map(&ActivityPub.unwrap/1)
    |> Enum.filter(&review?(&1, actor_id))
    |> Enum.take(@reviews_shown)
    |> Task.async_stream(&to_post/1, max_concurrency: @reviews_shown, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, %Post{} = post} -> [post]
      _ -> []
    end)
  end

  defp review?(%{"type" => "Article", "inReplyToBook" => book} = item, actor_id)
       when is_binary(book) do
    ActivityPub.attributed_to?(item, actor_id) and Fediverse.doc_public?(item)
  end

  defp review?(_item, _actor_id), do: false

  defp to_post(review) do
    url = review["url"] || review["id"]

    with true <- is_binary(url) and ChangesetHelpers.web_url?(url),
         published when is_binary(published) <- review["published"],
         {:ok, created_at, _offset} <- DateTime.from_iso8601(published),
         %Book{} = book <- book(review) do
      %Post{
        id: review["id"],
        url: url,
        text: ActivityPub.text(review),
        created_at: created_at,
        book: book
      }
    else
      _ -> nil
    end
  end

  # The review's own `name` is BookWyrm's generated heading in the author's
  # language — `Rezension von "Titel" (5 Sterne): Überschrift` — so the book's
  # title is also readable from it when the edition cannot be fetched.
  defp book(review) do
    name = to_string(review["name"])
    edition = edition(review["inReplyToBook"])
    title = (edition && Post.presence(edition["title"])) || quoted_title(name)

    if title do
      %Book{
        title: title,
        author: edition && author_name(edition),
        rating: rating(review["rating"]),
        headline: headline(name, title),
        cover: edition && cover(edition)
      }
    end
  end

  defp edition(url) do
    case get(url) do
      {:ok, %{"title" => title} = edition} when is_binary(title) -> edition
      _ -> nil
    end
  end

  defp author_name(%{"authors" => [author | _]}) when is_binary(author) do
    case get(author) do
      {:ok, %{"name" => name}} -> Post.presence(name)
      _ -> nil
    end
  end

  defp author_name(_edition), do: nil

  defp cover(%{"cover" => %{"url" => url}}) when is_binary(url),
    do: Http.fetch_avatar(url, @req_options)

  defp cover(_edition), do: nil

  defp rating(value) when is_number(value) and value > 0 and value <= 5, do: value / 1
  defp rating(_value), do: nil

  defp quoted_title(name) do
    case Regex.run(~r/"(.+?)"/u, name) do
      [_, title] -> Post.presence(title)
      nil -> nil
    end
  end

  # Whatever follows the quoted title, past the optional star count in
  # parentheses and the colon. A review without its own title has nothing there.
  defp headline(name, title) do
    case String.split(name, ~s("#{title}"), parts: 2) do
      [_, rest] ->
        case Regex.run(~r/^\s*(?:\([^)]*\))?\s*:\s*(.+)$/su, rest) do
          [_, headline] -> (headline = Post.presence(headline)) && Post.truncate(headline, 200)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp get(url), do: ActivityPub.get(url, @req_options)
end
