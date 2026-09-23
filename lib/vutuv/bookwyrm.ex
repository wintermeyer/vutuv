defmodule Vutuv.Bookwyrm do
  @moduledoc """
  The BookWyrm client of the inline social feeds (`Vutuv.SocialFeed`): fetches
  a member's latest public book reviews for the profile's "Book reviews" card.

  BookWyrm speaks ActivityPub but offers no Mastodon-compatible REST API, so
  this reads the public documents every federated server serves without
  credentials: WebFinger names the actor, the actor names its outbox, and the
  outbox's first page lists the member's statuses newest first. Only the
  reviews are kept (an `Article` with an `inReplyToBook`); the reading-status
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
  alias Vutuv.Fediverse.Handle
  alias Vutuv.RemoteHtml
  alias Vutuv.SocialFeed.Book
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  @reviews_shown 3

  # Same shape the SocialMediaAccount changeset enforces; no ":" keeps port
  # injection out of the URL (https, port 443 only).
  @handle_format ~r/^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$/u

  @activity_json "application/activity+json"

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :bookwyrm_req_options

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests):
  `{:ok, %Feed{}}` whose posts are the reviews, each with its `book`, or a
  classified `{:error, :gone | :transient}` like every feed client.
  """
  def fetch_posts(handle) do
    with {:ok, user, instance} <- split_handle(handle),
         {:ok, actor_id} <- webfinger(user, instance),
         {:ok, actor} <- fetch_actor(actor_id),
         {:ok, items} <- outbox_items(actor) do
      {:ok,
       %Feed{
         name:
           Handle.display_name(actor["name"]) || Post.presence(actor["preferredUsername"]) || user,
         handle: handle,
         url: actor_id,
         posts: reviews(items, actor_id)
       }}
    end
  rescue
    error ->
      Logger.warning("bookwyrm fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp split_handle(handle) do
    with true <- is_binary(handle) and Regex.match?(@handle_format, handle),
         [user, instance] <- String.split(handle, "@", parts: 2),
         false <- Vutuv.Ssrf.resolves_to_internal?(instance) do
      {:ok, user, instance}
    else
      _ -> {:error, :gone}
    end
  end

  defp webfinger(user, instance) do
    resource = URI.encode_www_form("acct:#{user}@#{instance}")

    case get(
           "https://#{instance}/.well-known/webfinger?resource=#{resource}",
           "application/jrd+json"
         ) do
      {:ok, %{"links" => links}} when is_list(links) ->
        case Enum.find(links, &(&1["rel"] == "self" and &1["type"] == @activity_json)) do
          %{"href" => href} when is_binary(href) -> {:ok, href}
          _ -> {:error, :gone}
        end

      {:error, :not_found} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  # The actor must name itself the way WebFinger named it: a document that
  # claims another id is not the account the member listed.
  defp fetch_actor(actor_id) do
    case get(actor_id) do
      {:ok, %{"id" => ^actor_id, "outbox" => outbox} = actor} when is_binary(outbox) ->
        {:ok, actor}

      {:error, :not_found} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  # The outbox and its pages live on the actor's own server.
  defp outbox_items(%{"id" => actor_id, "outbox" => outbox}) do
    with true <- Fediverse.same_host?(outbox, actor_id),
         {:ok, collection} <- get(outbox),
         {:ok, page} <- first_page(collection, actor_id) do
      {:ok, List.wrap(page["orderedItems"] || page["items"])}
    else
      _ -> {:error, :transient}
    end
  end

  defp first_page(%{"first" => %{} = page}, _actor_id), do: {:ok, page}

  defp first_page(%{"first" => first}, actor_id) when is_binary(first) do
    if Fediverse.same_host?(first, actor_id), do: get(first), else: {:error, :transient}
  end

  defp first_page(%{"orderedItems" => _} = collection, _actor_id), do: {:ok, collection}
  defp first_page(_collection, _actor_id), do: {:error, :transient}

  # The books are looked up side by side: each one costs up to three requests
  # (edition, author, cover), and the profile's spinner waits for all of them.
  defp reviews(items, actor_id) do
    items
    |> Enum.map(&unwrap/1)
    |> Enum.filter(&review?(&1, actor_id))
    |> Enum.take(@reviews_shown)
    |> Task.async_stream(&to_post/1, max_concurrency: @reviews_shown, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, %Post{} = post} -> [post]
      _ -> []
    end)
  end

  # BookWyrm lists the objects themselves; a server that wraps them in their
  # Create activity is read the same way.
  defp unwrap(%{"type" => "Create", "object" => %{} = object}), do: object
  defp unwrap(item), do: item

  defp review?(%{"type" => "Article", "inReplyToBook" => book} = item, actor_id)
       when is_binary(book) do
    item["attributedTo"] == actor_id and Fediverse.doc_public?(item)
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
        text: review_text(review),
        created_at: created_at,
        book: book
      }
    else
      _ -> nil
    end
  end

  # A content warning replaces the review, as it does for a Mastodon status.
  defp review_text(review) do
    summary = Post.presence(RemoteHtml.to_text(to_string(review["summary"])))

    cond do
      summary -> summary
      review["sensitive"] == true -> ""
      true -> RemoteHtml.to_text(to_string(review["content"]))
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

  # One guarded GET of a document a remote server named: https only, a host
  # that does not resolve into our own network, a capped body decoded here.
  defp get(url, accept \\ @activity_json) do
    with true <- ChangesetHelpers.web_url?(url),
         %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         {:ok, %Req.Response{status: status, body: body}} <-
           Http.get(url, @req_options, headers: [{"accept", accept}]) do
      cond do
        status in 200..299 -> decode(body)
        status in [404, 410] -> {:error, :not_found}
        true -> {:error, :status}
      end
    else
      _ -> {:error, :unreachable}
    end
  end

  defp decode(body) do
    case Http.decode(body) do
      {:ok, %{} = document} -> {:ok, document}
      _ -> {:error, :malformed}
    end
  end
end
