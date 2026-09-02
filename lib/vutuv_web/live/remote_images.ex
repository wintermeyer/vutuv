defmodule VutuvWeb.Live.RemoteImages do
  @moduledoc """
  Makes a picture on a cached post appear the moment there is something to show
  of it, on every page that draws one (issues #1801, #1927).

  The waiting tile prints a promise — "It appears here by itself once it is
  through" — and `VutuvWeb.PostComponents.remote_post_images/1` prints it on
  **six** surfaces: the feed, a cached post's own page, the account page, the
  URL lookup, a tag timeline and an organization's feed. The promise was false
  on all six, because `Vutuv.Moderation.ImageSubjects` announced these verdicts
  to nobody (they are the ownerless scans, and its broadcast goes to the
  uploader's topic). The card kept whatever it was first drawn with until the
  reader pressed reload — which for a boosted photo post is the wordless tile,
  the delivery drawing the card a second before the bytes land.

  **The verdict was only half of it.** A card is drawn at delivery, when the
  picture is recorded and its bytes are not here yet; a second later they are,
  and from then on there is a mosaic preview to stand in for the picture
  (issue #1720). Waiting for the gate to say so meant nobody ever saw that
  mosaic on a post arriving in front of them — the wordless tile held the card
  for the whole scan, a median of 97 seconds. So `Vutuv.Fediverse.Media` now
  announces the bytes landing as well, and this hook re-reads on both.

  It is an `on_mount` hook for the reason `VutuvWeb.Live.RemoteCounts` is one: a
  guarantee the shared component makes on six pages must not depend on six hosts
  each remembering to subscribe, and a host that forgets simply never updates —
  nothing fails and nothing logs.

  ## Two modes, because the pictures are held in two shapes

      on_mount({VutuvWeb.Live.RemoteImages, {:assigns, :remote_post}})

  for a page whose pictures are one `@images` assign — a bare list where the
  page is about a single cached post, or the `%{post_id => [picture]}` map a
  listing holds — plus the cached post itself, under the assign named here (one
  `%RemotePost{}` or a list of them), because the post carries the other
  picture a card draws: its link capture. The hook owns both end to end and the
  host writes no `handle_info/2` at all. The name is stated rather than hunted
  for, and `Map.fetch!/2` raises on the next event if it ever stops being true;
  the three pages call it `:remote_post`, `:post` and `:posts`.

      on_mount(VutuvWeb.Live.RemoteImages)

  for a timeline, whose pictures ride each entry and whose cards live in a
  stream. That cannot be done from here — the stream's name and the entry's
  identity are the host's — so the hook only subscribes and the host writes one
  `handle_info/2` clause over `restate_entries/3`.
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

  def on_mount({:assigns, post_key}, _params, _session, socket) do
    if connected?(socket) do
      Fediverse.subscribe_remote_images()
      hook = &reload_assigns(&1, &2, post_key)
      {:cont, attach_hook(socket, :remote_images, :handle_info, hook)}
    else
      {:cont, socket}
    end
  end

  defp reload_assigns({:remote_images_changed, %{remote_post_id: id}}, socket, post_key) do
    {:halt, restate_assigns(socket, post_key, id)}
  end

  defp reload_assigns(_other, socket, _post_key), do: {:cont, socket}

  @doc """
  Every picture one cached post's card draws: the author's attachments and,
  where there are none, the link capture taken of the one URL such a post can
  carry.

  One read, because both arrive at a card together and a reader does not sort a
  card's pictures by which table they came from. The capture is read **only for
  a post with no attachments**, which is the only case a card draws one at all
  (`remote_link_screenshot/2` matches an empty picture list), so a photo post —
  exactly what the byte-landing announcement fires for — pays one query rather
  than two.
  """
  def pictures(remote_post_id) when is_binary(remote_post_id) do
    case Fediverse.remote_images(remote_post_id) do
      [] -> %{images: [], screenshot: Fediverse.remote_screenshot(remote_post_id)}
      images -> %{images: images, screenshot: :unread}
    end
  end

  @doc """
  Whether one feed entry draws `remote_post_id` at all — as its own card, or as
  the parent it nests.

  The timeline twin of the check the `:assigns` mode makes for itself, and it
  exists for the same reason: every open page hears about every picture, so a
  host must be able to answer "not mine" without going to the database.
  """
  def draws?(entry, remote_post_id),
    do: Enum.any?(cards(entry), &match?(%{remote_post: %RemotePost{id: ^remote_post_id}}, &1))

  @doc """
  A timeline's entries with `remote_post_id`'s pictures re-read, and the ones
  that really moved.

  Returns `{entries, changed}` — the host knows its stream's name and nothing
  else about this, so it spends the second element on `stream_insert/4` and
  keeps the first.
  """
  def restate_entries(entries, remote_post_id, pictures) do
    Enum.map_reduce(entries, [], fn entry, changed ->
      case restate_entry(entry, remote_post_id, pictures) do
        ^entry -> {entry, changed}
        updated -> {updated, [updated | changed]}
      end
    end)
  end

  @doc """
  The same for one feed entry: the cached post it draws, plus any it nests as a
  parent, which is a second card carrying a second copy of the same wait.

  Returns the entry unchanged when it draws neither, so a caller can compare
  identity to find the cards that really moved.
  """
  def restate_entry(entry, remote_post_id, pictures) do
    entry
    |> restate_card(remote_post_id, pictures)
    |> Map.replace_lazy(:remote_parents, fn parents ->
      Map.new(parents, fn {key, parent} ->
        {key, restate_card(parent, remote_post_id, pictures)}
      end)
    end)
  end

  # One card, whether it is the entry itself or the parent another card nests:
  # both are built by `Vutuv.Posts.attach_remote_images/1`, so both are the same
  # shape. The capture rides the post it hangs off rather than an assign of its
  # own, which is why it is written back onto the struct here.
  defp restate_card(%{remote_post: %RemotePost{id: id}} = card, id, pictures) do
    card
    |> Map.put(:images, pictures.images)
    |> Map.put(:remote_post, put_screenshot(card.remote_post, id, pictures.screenshot))
  end

  defp restate_card(card, _remote_post_id, _pictures), do: card

  # An entry draws one cached post of its own at most, and nests at most one per
  # thread post above it (`Vutuv.Posts.attach_remote_parents/3`).
  defp cards(entry), do: [entry | Map.values(entry[:remote_parents] || %{})]

  # The `:assigns` mode's own restate: the `@images` assign the mode is named
  # for, and the cached post, which carries the link capture. Every open page
  # hears about every picture, so the two cheap "is it even on this page"
  # questions come before the read.
  defp restate_assigns(socket, post_key, remote_post_id) do
    images = socket.assigns.images
    posts = Map.fetch!(socket.assigns, post_key)

    if holds_images?(images, remote_post_id) or holds_post?(posts, remote_post_id) do
      pictures = pictures(remote_post_id)

      socket
      |> assign(:images, put_images(images, remote_post_id, pictures.images))
      |> assign(post_key, put_screenshot(posts, remote_post_id, pictures.screenshot))
    else
      socket
    end
  end

  defp holds_images?(images, remote_post_id) when is_map(images),
    do: Map.has_key?(images, remote_post_id)

  defp holds_images?(images, remote_post_id) when is_list(images),
    do: Enum.any?(images, &(&1.remote_post_id == remote_post_id))

  defp holds_post?(%RemotePost{id: id}, id), do: true

  defp holds_post?(values, remote_post_id) when is_list(values),
    do: Enum.any?(values, &holds_post?(&1, remote_post_id))

  defp holds_post?(_value, _remote_post_id), do: false

  # A listing keeps a map keyed by post id, and the fresh set goes in whether or
  # not the post had a key: an author can add a picture to a post that had none.
  defp put_images(images, remote_post_id, fresh) when is_map(images),
    do: Map.put(images, remote_post_id, fresh)

  # A bare list is one post's pictures, and the caller has already established
  # that this page is showing that post, so the fresh set replaces it whole.
  defp put_images(images, _remote_post_id, fresh) when is_list(images), do: fresh

  # `:unread` is `pictures/1` saying it did not look at the capture, because a
  # post with attachments never draws one — so leave the post's own alone rather
  # than writing a nil nobody read.
  defp put_screenshot(post, _remote_post_id, :unread), do: post

  defp put_screenshot(%RemotePost{id: id} = post, id, screenshot),
    do: %{post | screenshot: screenshot}

  defp put_screenshot(values, remote_post_id, screenshot) when is_list(values),
    do: Enum.map(values, &put_screenshot(&1, remote_post_id, screenshot))

  defp put_screenshot(value, _remote_post_id, _screenshot), do: value
end
