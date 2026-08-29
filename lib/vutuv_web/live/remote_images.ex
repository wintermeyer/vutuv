defmodule VutuvWeb.Live.RemoteImages do
  @moduledoc """
  Makes a picture on a cached post appear the moment the AI gate releases it,
  on every page that draws one (issue #1801).

  The waiting tile prints a promise — "It appears here by itself once it is
  through" — and `VutuvWeb.PostComponents.remote_post_images/1` prints it on
  **six** surfaces: the feed, a cached post's own page, the account page, the
  URL lookup, a tag timeline and an organization's feed. The promise was false
  on all six, because `Vutuv.Moderation.ImageSubjects` announced these verdicts
  to nobody (they are the ownerless scans, and its broadcast goes to the
  uploader's topic). The card kept whatever it was first drawn with until the
  reader pressed reload — which for a boosted photo post is the wordless tile,
  the delivery drawing the card a second before the bytes land.

  It is an `on_mount` hook for the reason `VutuvWeb.Live.RemoteCounts` is one: a
  guarantee the shared component makes on six pages must not depend on six hosts
  each remembering to subscribe, and a host that forgets simply never updates —
  nothing fails and nothing logs.

  ## Two modes, because the pictures are held in two shapes

      on_mount({VutuvWeb.Live.RemoteImages, :assigns})

  for a page whose pictures are one `@images` assign: a bare list where the page
  is about a single cached post, or the `%{post_id => [picture]}` map a listing
  holds. The hook owns it end to end and the host writes no `handle_info/2` at
  all.

      on_mount(VutuvWeb.Live.RemoteImages)

  for a timeline, whose pictures ride each entry and whose cards live in a
  stream. That cannot be done from here — the stream's name and the entry's
  identity are the host's — so the hook only subscribes and the host writes one
  `handle_info/2` clause over `restate_entry/3`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemotePost

  # Connected sockets only, in both modes: the dead render is replaced the
  # moment the socket joins, so subscribing for it would be a subscription
  # nobody reads.
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Fediverse.subscribe_remote_images()
    {:cont, socket}
  end

  def on_mount(:assigns, _params, _session, socket) do
    if connected?(socket) do
      Fediverse.subscribe_remote_images()
      {:cont, attach_hook(socket, :remote_images, :handle_info, &reload_assign/2)}
    else
      {:cont, socket}
    end
  end

  defp reload_assign({:remote_images_settled, %{remote_post_id: id}}, socket) do
    {:halt, assign(socket, :images, reload(socket.assigns.images, id))}
  end

  defp reload_assign(_other, socket), do: {:cont, socket}

  @doc """
  One page's pictures with `remote_post_id`'s set re-read, keeping the shape it
  was given.

  Answers the assign unchanged — and reads nothing — when this page is not
  showing that post, which is the common case on a topic every page hears.
  """
  def reload(images, remote_post_id) when is_map(images) do
    if Map.has_key?(images, remote_post_id),
      do: Map.put(images, remote_post_id, Fediverse.remote_images(remote_post_id)),
      else: images
  end

  def reload(images, remote_post_id) when is_list(images) do
    if Enum.any?(images, &(&1.remote_post_id == remote_post_id)),
      do: Fediverse.remote_images(remote_post_id),
      else: images
  end

  @doc """
  Whether one feed entry draws `remote_post_id` at all — as its own card, or as
  the parent it nests.

  The timeline twin of the check `reload/2` makes for itself, and it exists for
  the same reason: every open page hears every verdict, so a host must be able
  to answer "not mine" without going to the database.
  """
  def draws?(entry, remote_post_id),
    do: Enum.any?(cards(entry), &match?(%{remote_post: %RemotePost{id: ^remote_post_id}}, &1))

  @doc """
  The same for one feed entry: the cached post it draws, plus any it nests as a
  parent, which is a second card carrying a second copy of the same wait.

  Returns the entry unchanged when it draws neither, so a caller can compare
  identity to find the cards that really moved.
  """
  def restate_entry(entry, remote_post_id, images) do
    entry
    |> restate_card(remote_post_id, images)
    |> Map.replace_lazy(:remote_parents, fn parents ->
      Map.new(parents, fn {key, parent} -> {key, restate_card(parent, remote_post_id, images)} end)
    end)
  end

  # One card, whether it is the entry itself or the parent another card nests:
  # both are built by `Vutuv.Posts.attach_remote_images/1`, so both are the same
  # shape.
  defp restate_card(%{remote_post: %RemotePost{id: id}} = card, id, images),
    do: Map.put(card, :images, images)

  defp restate_card(card, _remote_post_id, _images), do: card

  # An entry draws one cached post of its own at most, and nests at most one per
  # thread post above it (`Vutuv.Posts.attach_remote_parents/3`).
  defp cards(entry), do: [entry | Map.values(entry[:remote_parents] || %{})]
end
