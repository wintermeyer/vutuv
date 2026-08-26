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

  What differs per surface is only how the answer is shown — the permalink
  writes its own `:notice` assign, the feed a flash — and what to do with the
  space the card leaves. So this returns the outcome and its sentence, and each
  host says it its own way; sharing the sentences is the point, since they are
  what drifts when the same act is spelled twice.
  """

  use Gettext, backend: VutuvWeb.Gettext

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
