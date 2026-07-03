defmodule Vutuv.Bluesky do
  @moduledoc """
  The Bluesky client of the inline social feeds (`Vutuv.SocialFeed`): fetches
  a member's latest public Bluesky posts for the profile's "Social media
  posts" card.

  Unlike Mastodon there is no member-supplied server to talk to: every stored
  handle (a domain like `name.bsky.social`, see
  `Vutuv.Profiles.SocialMediaAccount`) is asked at the network's one public,
  credential-less AppView (`public.api.bsky.app`). `fetch_posts/1` resolves
  the account (`app.bsky.actor.getProfile`) and reads its author feed
  (`app.bsky.feed.getAuthorFeed`), reduced to plain-text
  `Vutuv.SocialFeed.Post`s — post text arrives as plain text in the record
  (no HTML to strip), and is HEEx-escaped at render time. It never runs in a
  request or LiveView process — `Vutuv.SocialFeed.Cache` owns the fetch tasks;
  pages talk to `Vutuv.SocialFeed` only.

  An account whose profile carries the `!no-unauthenticated` self-label asks
  not to be shown to signed-out visitors. The profile card is a public
  surface, so such an account yields an **empty** feed (a success — the
  member listing the account keeps working, we just show nothing).
  """

  require Logger

  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  # The public, credential-less AppView — a fixed host, never member input.
  @appview "https://public.api.bsky.app"

  # How many posts the profile shows, from how many fetched (replies are
  # excluded server-side; reposts, pins and labeled posts are dropped here).
  @posts_shown 3
  @feed_limit 20

  # Bluesky caps posts at 300 graphemes; the guard matches Mastodon's anyway.
  @max_text_length 500

  # A Bluesky handle is a lowercase domain (name.bsky.social, or a custom
  # domain). Only this shape may be embedded in the AppView query and the
  # bsky.app profile/post URLs.
  @handle_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/

  # A record key from the post's at:// URI; anything else must not be
  # embedded in the post URL.
  @rkey_format ~r/^[A-Za-z0-9._~-]+$/

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :bluesky_req_options

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests):
  `{:ok, %Feed{}}` or a classified `{:error, :gone | :transient}` — `:gone` is
  a hard error that deactivates the account immediately, `:transient` walks
  the backoff ladder. The avatar is best-effort: any problem with it leaves
  `feed.avatar` nil, never a failed feed.
  """
  def fetch_posts(handle) do
    with {:ok, handle} <- normalize_handle(handle),
         {:ok, meta} <- fetch_profile(handle) do
      build_feed(handle, meta)
    end
  rescue
    error ->
      Logger.warning("bluesky fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  defp build_feed(handle, meta) do
    feed = %Feed{
      name: meta.name,
      handle: handle,
      url: "https://bsky.app/profile/#{handle}",
      avatar: nil,
      posts: []
    }

    if meta.hidden_when_logged_out? do
      {:ok, feed}
    else
      with {:ok, posts} <- fetch_feed(handle) do
        avatar = Http.fetch_avatar(meta.avatar_url, @req_options)
        {:ok, %{feed | avatar: avatar, posts: posts}}
      end
    end
  end

  # Legacy rows may carry a leading "@" or mixed case; the changeset stores
  # the normalized form for new entries.
  defp normalize_handle(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    if Regex.match?(@handle_format, normalized) do
      {:ok, normalized}
    else
      {:error, :gone}
    end
  end

  defp normalize_handle(_handle), do: {:error, :gone}

  defp fetch_profile(handle) do
    url = @appview <> "/xrpc/app.bsky.actor.getProfile?actor=" <> URI.encode_www_form(handle)

    case Http.get(url, @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Http.decode(body) do
          {:ok, %{"handle" => _} = profile} -> {:ok, profile_meta(profile, handle)}
          _ -> {:error, :transient}
        end

      # The AppView answers 400 for an unknown, deactivated or taken-down
      # actor ("Profile not found") — the account is not coming back on its
      # own, exactly like a Mastodon 404.
      {:ok, %Req.Response{status: 400}} ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  defp profile_meta(profile, handle) do
    %{
      name: presence(profile["displayName"]) || handle,
      avatar_url: presence(profile["avatar"]),
      hidden_when_logged_out?: has_label?(profile["labels"], "!no-unauthenticated")
    }
  end

  defp has_label?(labels, value) when is_list(labels),
    do: Enum.any?(labels, &(is_map(&1) and &1["val"] == value))

  defp has_label?(_labels, _value), do: false

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp fetch_feed(handle) do
    url =
      @appview <>
        "/xrpc/app.bsky.feed.getAuthorFeed?actor=#{URI.encode_www_form(handle)}" <>
        "&limit=#{@feed_limit}&filter=posts_no_replies"

    with {:ok, %Req.Response{status: 200, body: body}} <- Http.get(url, @req_options),
         {:ok, %{"feed" => items}} when is_list(items) <- Http.decode(body) do
      {:ok, parse_items(items, handle)}
    else
      {:ok, %Req.Response{status: 400}} -> {:error, :gone}
      _ -> {:error, :transient}
    end
  end

  # An item carrying a `reason` is not the account's own chronological post:
  # a repost of someone else, or the pinned copy of a post that also appears
  # in place. Items whose post carries any moderation/self label (porn,
  # graphic-media, spam, ...) are skipped wholesale, like a Mastodon
  # sensitive-without-spoiler status.
  defp parse_items(items, handle) do
    items
    |> Enum.reject(&Map.has_key?(&1, "reason"))
    |> Enum.flat_map(fn item ->
      case to_post(item, handle) do
        nil -> []
        post -> [post]
      end
    end)
    |> Enum.take(@posts_shown)
  end

  defp to_post(%{"post" => %{"uri" => uri, "record" => record} = post}, handle)
       when is_binary(uri) and is_map(record) do
    text = record["text"] |> to_string() |> String.trim() |> truncate()
    created = record["createdAt"]
    rkey = uri |> String.split("/") |> List.last()

    with [] <- List.wrap(post["labels"]),
         false <- Map.has_key?(record, "reply"),
         true <- text != "" and is_binary(created),
         # The rkey came from the remote JSON; only a plain token may be
         # embedded in the post URL.
         true <- is_binary(rkey) and Regex.match?(@rkey_format, rkey),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(created) do
      %Post{
        id: rkey,
        url: "https://bsky.app/profile/#{handle}/post/#{rkey}",
        text: text,
        created_at: created_at
      }
    else
      _ -> nil
    end
  end

  defp to_post(_item, _handle), do: nil

  defp truncate(text) do
    if String.length(text) > @max_text_length do
      String.slice(text, 0, @max_text_length - 1) <> "…"
    else
      text
    end
  end
end
