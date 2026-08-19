defmodule VutuvWeb.Live.RemotePostActions do
  @moduledoc """
  The three acts a cached post's ⋯ menu offers — report it, mute its author,
  unfollow its author — once, for every surface that renders the card (the feed,
  the tag timeline, an account's page, the URL lookup, the post's own page, the
  saved list, the answering page — and any card that follows them).

  A report deletes our copy immediately (`Vutuv.Fediverse.report_remote_post/2`)
  — this is a cache of something that still exists at its origin, so there is no
  case and no freezer — and the member is told so in the same round trip. What
  differs per page is only what to do with the space the card leaves behind:
  drop the row, reload the list, clear the result, or navigate away. That is the
  `on_removed` function; everything else was copied five times, including both
  member-facing sentences, which is five chances for one of them to drift into a
  second wording for the same act.

  The `:not_found` arm runs `on_removed` too and says nothing: the copy is
  already gone, which is exactly what the member asked for, so reporting an
  error would be a lie about a request that succeeded. `unfollow/3` answers a
  follow that is already gone the same way, for the same reason.

  A surface that renders the menu **must** handle all three events — an
  unhandled `phx-click` takes the LiveView down, so a card whose host forgot one
  is a button that kills the page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Vutuv.Fediverse

  @doc """
  Handles a `"report-remote-post"` event for the cached post `id`, returning the
  `{:noreply, socket}` its `handle_event/3` clause can return directly.

  `on_removed` takes the socket and returns it, and runs wherever the card has
  to leave the page.
  """
  def report(socket, id, on_removed) when is_function(on_removed, 1) do
    case Fediverse.report_remote_post(id, socket.assigns.current_user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Thank you. Our copy was deleted right away."))
         |> on_removed.()}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You have reported a lot today. Please try again tomorrow.")
         )}

      {:error, :not_found} ->
        {:noreply, on_removed.(socket)}
    end
  end

  @doc """
  Handles a `"mute-remote-account"` event for the account `id`: the private,
  reversible "not this account today". The follow stays; its posts leave the
  feed, so `on_muted` is where a surface takes the rows away.
  """
  def mute(socket, account_id, on_muted) when is_function(on_muted, 1) do
    :ok = Fediverse.set_remote_follow_mute(socket.assigns.current_user, account_id, true)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Muted. You still follow them; their posts leave your feed."))
     |> on_muted.()}
  end

  @doc """
  Handles an `"unfollow-remote-account"` event for the account `id`: the member
  takes the follow back, wherever they are reading (the card asks first).

  The cached posts existed because somebody here follows the author, so
  `Vutuv.Fediverse.unfollow_remote/2` deletes them when nobody does any more —
  which is why `on_removed` runs on both arms: the rows this member is looking
  at may be gone from the database by the time it returns.
  """
  def unfollow(socket, account_id, on_removed) when is_function(on_removed, 1) do
    case Fediverse.unfollow_remote_account(socket.assigns.current_user, account_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Unfollowed. Their posts leave your feed."))
         |> on_removed.()}

      {:error, :not_found} ->
        {:noreply, on_removed.(socket)}
    end
  end
end
