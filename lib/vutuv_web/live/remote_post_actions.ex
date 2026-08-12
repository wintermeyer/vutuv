defmodule VutuvWeb.Live.RemotePostActions do
  @moduledoc """
  Reporting a cached post from another network, once, for the six surfaces that
  offer it (the feed, the tag timeline, an account's page, the URL lookup, the
  post's own page — and any card that follows them).

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
  error would be a lie about a request that succeeded.
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
end
