defmodule Vutuv.SocialFeed.ActivityPub do
  @moduledoc """
  The ActivityPub half of the feed clients whose network offers no public
  Mastodon-compatible REST API (`Vutuv.Bookwyrm`, `Vutuv.Friendica`). They read
  the documents every federated server serves without credentials: WebFinger
  names the actor, the actor names its outbox, and the outbox's first page
  lists the account's activities newest first.

  Every request goes through `get/3`: https only, a host that does not resolve
  into our own network, a capped body. Each function takes the client's
  req-options key, the seam its tests stub HTTP through.
  """

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Handle
  alias Vutuv.RemoteHtml
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  @activity_json "application/activity+json"

  # Same shape the SocialMediaAccount changeset enforces; no ":" keeps port
  # injection out of the URL (https, port 443 only).
  @handle_format ~r/^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$/u

  @doc """
  Resolves a stored `user@instance` handle to its actor document:
  `{:ok, actor, links}` with the WebFinger `links` beside it (a server may name
  the avatar only there), or a classified `{:error, :gone | :transient}` like
  every feed client's.
  """
  def resolve(handle, options_key) do
    with {:ok, user, instance} <- split_handle(handle),
         {:ok, actor_id, links} <- webfinger(user, instance, options_key),
         {:ok, actor} <- fetch_actor(actor_id, options_key) do
      {:ok, actor, links}
    end
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

  defp webfinger(user, instance, options_key) do
    resource = URI.encode_www_form("acct:#{user}@#{instance}")

    case get(
           "https://#{instance}/.well-known/webfinger?resource=#{resource}",
           options_key,
           "application/jrd+json"
         ) do
      {:ok, %{"links" => links}} when is_list(links) ->
        case Enum.find(links, &(&1["rel"] == "self" and &1["type"] == @activity_json)) do
          %{"href" => href} when is_binary(href) -> {:ok, href, links}
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
  defp fetch_actor(actor_id, options_key) do
    case get(actor_id, options_key) do
      {:ok, %{"id" => ^actor_id, "outbox" => outbox} = actor} when is_binary(outbox) ->
        {:ok, actor}

      {:error, :not_found} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  @doc """
  The items on the first page of the actor's outbox, newest first. The outbox
  and its pages must live on the actor's own server.
  """
  def outbox_items(%{"id" => actor_id, "outbox" => outbox}, options_key) do
    with true <- Fediverse.same_host?(outbox, actor_id),
         {:ok, collection} <- get(outbox, options_key),
         {:ok, page} <- first_page(collection, actor_id, options_key) do
      {:ok, List.wrap(page["orderedItems"] || page["items"])}
    else
      _ -> {:error, :transient}
    end
  end

  defp first_page(%{"first" => %{} = page}, _actor_id, _options_key), do: {:ok, page}

  defp first_page(%{"first" => first}, actor_id, options_key) when is_binary(first) do
    if Fediverse.same_host?(first, actor_id),
      do: get(first, options_key),
      else: {:error, :transient}
  end

  defp first_page(%{"orderedItems" => _} = collection, _actor_id, _options_key),
    do: {:ok, collection}

  defp first_page(_collection, _actor_id, _options_key), do: {:error, :transient}

  @doc """
  An outbox item as the object it is about: servers either list the objects
  themselves (BookWyrm) or wrap each in its `Create` activity (Friendica,
  Mastodon).
  """
  def unwrap(%{"type" => "Create", "object" => %{} = object}), do: object
  def unwrap(item), do: item

  @doc """
  Whether `object` names `actor_id` as its author. `attributedTo` is a bare id
  on BookWyrm and Mastodon but the embedded actor document on Friendica.
  """
  def attributed_to?(object, actor_id),
    do: Fediverse.activity_object_id(object["attributedTo"]) == actor_id

  @doc """
  The name a feed card shows for the actor: its display name, else its
  `preferredUsername`, else the user part of the handle the member listed.
  """
  def display_name(actor, handle) do
    Handle.display_name(actor["name"]) || Post.presence(actor["preferredUsername"]) ||
      handle |> String.split("@") |> hd()
  end

  @doc """
  An object's text as the card shows it, reduced to plain text: a content
  warning replaces the content, and sensitive media without one yields `""`,
  which drops the post, as for a Mastodon status. With `title: true` the
  object's `name` leads the content (a Friendica `Article`); BookWyrm's `name`
  is a generated heading the card shows elsewhere, so it stays off by default.
  """
  def text(object, opts \\ []) do
    summary = Post.presence(RemoteHtml.to_text(to_string(object["summary"])))

    cond do
      summary -> Post.truncate(summary)
      object["sensitive"] == true -> ""
      opts[:title] -> with_title(object["name"], content(object))
      true -> content(object)
    end
  end

  defp content(object),
    do: RemoteHtml.to_text(to_string(object["content"]), nil, List.wrap(object["tag"]))

  defp with_title(name, body) do
    case Post.presence(RemoteHtml.to_text(to_string(name))) do
      nil -> body
      title when body == "" -> title
      title -> title <> "\n\n" <> body
    end
  end

  @doc """
  One guarded GET of a document a remote server named: https only, a host that
  does not resolve into our own network, a capped body decoded here.
  `{:error, :not_found}` for a 404 or 410, so a caller can tell a vanished
  account from a struggling server.
  """
  def get(url, options_key, accept \\ @activity_json) do
    with true <- ChangesetHelpers.web_url?(url),
         %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         {:ok, %Req.Response{status: status, body: body}} <-
           Http.get(url, options_key, headers: [{"accept", accept}]) do
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
