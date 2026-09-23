defmodule Vutuv.Friendica do
  @moduledoc """
  The Friendica client of the inline social feeds (`Vutuv.SocialFeed`):
  fetches a member's latest public Friendica posts for the profile's "Social
  media posts" card, beside the Mastodon and Bluesky ones.

  Friendica serves a Mastodon-compatible API, but the call `Vutuv.Mastodon`
  starts with, `/api/v1/accounts/lookup`, answers `401` without a login, and
  looking an account up by its nickname instead can return a different
  account of the same name on another server. So this reads the public
  ActivityPub outbox (`Vutuv.SocialFeed.ActivityPub`), which needs no
  credentials: every public `Note` or `Article` the account wrote itself, not
  a reply, becomes a post. The follower count is the `totalItems` of the
  followers collection and the avatar the actor's `icon` or WebFinger's avatar
  link; either failing leaves it nil rather than failing the feed.

  Like the other clients it never runs in a request or LiveView process
  (`Vutuv.SocialFeed.Cache` owns the fetch tasks), and the remote `content` is
  reduced to plain text here and HEEx-escaped at render time — never render
  any of it with `raw/1`.
  """

  require Logger

  alias Vutuv.ChangesetHelpers
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Media
  alias Vutuv.SocialFeed.ActivityPub
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post

  @posts_shown 3

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :friendica_req_options

  @doc """
  The blocking fetch (run inside the cache's task, and directly by tests):
  `{:ok, %Feed{}}` or a classified `{:error, :gone | :transient}` like every
  feed client.
  """
  def fetch_posts(handle) do
    with {:ok, actor, links} <- ActivityPub.resolve(handle, @req_options) do
      # The avatar (with its image scan) and the follower count do not depend on
      # the outbox, so they are fetched beside it rather than after it.
      extras = Task.async(fn -> {avatar(actor, links), followers(actor)} end)

      case ActivityPub.outbox_items(actor, @req_options) do
        {:ok, items} ->
          {avatar, followers} = Task.await(extras, :infinity)

          {:ok,
           %Feed{
             name: ActivityPub.display_name(actor, handle),
             handle: handle,
             url: profile_url(actor),
             avatar: avatar,
             followers: followers,
             posts: posts(items, actor["id"])
           }}

        error ->
          Task.shutdown(extras, :brutal_kill)
          error
      end
    end
  rescue
    error ->
      Logger.warning("friendica fetch for #{inspect(handle)} raised: #{inspect(error)}")
      {:error, :transient}
  end

  # The actor's `url` is its profile page; an unusable one falls back to the id,
  # which Friendica serves the same page at.
  defp profile_url(actor) do
    if ChangesetHelpers.web_url?(actor["url"]), do: actor["url"], else: actor["id"]
  end

  # Friendica leaves `icon` out of the actor it serves an anonymous reader, so
  # WebFinger's avatar link is the usual source.
  defp avatar(actor, links) do
    url =
      Media.actor_icon_url(actor) ||
        Enum.find_value(links, &(&1["rel"] == "http://webfinger.net/rel/avatar" && &1["href"]))

    if is_binary(url) and Fediverse.same_host?(url, actor["id"]),
      do: Http.fetch_avatar(url, @req_options)
  end

  defp followers(%{"followers" => url, "id" => actor_id}) when is_binary(url) do
    with true <- Fediverse.same_host?(url, actor_id),
         {:ok, %{"totalItems" => count}} <- ActivityPub.get(url, @req_options) do
      Feed.follower_count(count)
    else
      _ -> nil
    end
  end

  defp followers(_actor), do: nil

  # Boosts (`Announce`) are skipped: only what the account wrote itself.
  defp posts(items, actor_id) do
    for(%{"type" => "Create", "object" => %{} = note} <- items, do: note)
    |> Stream.filter(&own_public_note?(&1, actor_id))
    |> Stream.map(&to_post/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.take(@posts_shown)
  end

  # A post with a title is an `Article` on Friendica, one without a `Note`.
  defp own_public_note?(%{"type" => type} = note, actor_id) when type in ["Note", "Article"] do
    ActivityPub.attributed_to?(note, actor_id) and is_nil(note["inReplyTo"]) and
      Fediverse.doc_public?(note)
  end

  defp own_public_note?(_item, _actor_id), do: false

  # A note with no usable permalink is dropped rather than rendered: the card
  # is a link to the original, so there is nothing to show without one.
  defp to_post(note) do
    url = note["url"] || note["id"]
    text = ActivityPub.text(note, title: true)

    with true <- ChangesetHelpers.web_url?(url) and text != "",
         published when is_binary(published) <- note["published"],
         {:ok, created_at, _offset} <- DateTime.from_iso8601(published) do
      %Post{id: note["id"], url: url, text: text, created_at: created_at}
    else
      _ -> nil
    end
  end
end
