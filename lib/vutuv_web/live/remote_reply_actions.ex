defmodule VutuvWeb.Live.RemoteReplyActions do
  @moduledoc """
  The two acts a remote reply's ⋯ menu offers — the post's author removes it,
  anybody who can read it reports it — once, for every surface that renders
  `VutuvWeb.PostComponents.remote_reply_card/1`.

  The sibling of `VutuvWeb.Live.RemotePostActions` one subject over, and it
  exists for the same reason: **an unhandled `phx-click` takes the LiveView
  down**, so a card whose host forgot one of its events is a button that kills
  the page. That had already happened — the feed drew this card for a reshared
  reply (issue #1275) while only the permalink handled `remove-remote-reply` /
  `report-remote-reply`, so Report was a page-killer there for anyone who
  pressed it.

  Both acts **delete our copy at once** (`Vutuv.Fediverse`), which is the whole
  workflow: unlike a member's own post this is a cache of something that still
  exists at its origin, so there is no case and no freezer. A report also goes
  out to that origin as a `Flag`.

  What differs per surface is only how the answer is shown and what to do with
  the space the card leaves. The permalink writes its own `:notice` assign, so
  it takes the outcome and its sentence from `remove/2` and `report/2`. Every
  other host (the feed, the saved list, the answering page) says it with a
  flash, so it hands `remove/3` and `report/3` the one step that differs: drop
  the row, reload the list, or navigate away. Sharing the sentences is the
  point, since they are what drifts when the same act is spelled twice. The
  saved list and the answering page both drew the card without the handler
  until the flash variant made it one line.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse

  @doc """
  The member takes a reply from another network off their own post.

  Returns `{:ok, message}` when it is gone, `{:error, message}` when it is not,
  and `{:error, nil}` for a viewer who is not signed in at all — nothing to say
  to somebody the menu was never rendered for.
  """
  def remove(note_id, viewer),
    do: take_down(&Fediverse.remove_note/2, note_id, viewer, gettext("Reply removed."))

  @doc """
  Anybody who can see the reply marks it as not appropriate. Same shape as
  `remove/2`.
  """
  def report(note_id, viewer) do
    take_down(
      &Fediverse.report_note/2,
      note_id,
      viewer,
      gettext("Thank you. The reply was deleted right away.")
    )
  end

  @doc """
  `remove/2` for a host that answers with a flash: returns the `{:noreply,
  socket}` its `handle_event/3` clause can return directly. `on_removed` takes
  the socket and returns it, and runs once the reply is gone.
  """
  def remove(socket, note_id, on_removed) when is_function(on_removed, 1),
    do: flashed(socket, remove(note_id, socket.assigns[:current_user]), on_removed)

  @doc "`report/2` for a host that answers with a flash, as `remove/3`."
  def report(socket, note_id, on_removed) when is_function(on_removed, 1),
    do: flashed(socket, report(note_id, socket.assigns[:current_user]), on_removed)

  defp flashed(socket, {:ok, done}, on_removed),
    do: {:noreply, socket |> put_flash(:info, done) |> on_removed.()}

  defp flashed(socket, {:error, nil}, _on_removed), do: {:noreply, socket}

  defp flashed(socket, {:error, message}, _on_removed),
    do: {:noreply, put_flash(socket, :error, message)}

  defp take_down(fun, note_id, %User{} = viewer, done) do
    case fun.(note_id, viewer) do
      :ok ->
        {:ok, done}

      {:error, :rate_limited} ->
        {:error, gettext("You have reported a lot today. Please try again tomorrow.")}

      _ ->
        {:error, gettext("That reply is not yours to remove.")}
    end
  end

  defp take_down(_fun, _note_id, _viewer, _done), do: {:error, nil}
end
