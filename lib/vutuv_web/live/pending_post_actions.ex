defmodule VutuvWeb.Live.PendingPostActions do
  @moduledoc """
  The two ways out of a waiting post (issue #2106), for the surfaces that draw
  the card: the feed and the author's own `/system/uploads`.

  Both events come from one component (`VutuvWeb.PendingPostComponents`), so
  the act belongs beside it rather than being written out in each host — a
  third surface showing the card would otherwise be a third copy, and the next
  change (a flash, an error path) four edits instead of two.

  Both are `phx-click` events and never links, because each destroys state: a
  state-destroying GET dies on a Back button, a breadcrumb or a link prefetch,
  none of which a ConnTest ever performs.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Posts.Pending

  @events ~w(cancel-pending-post publish-without-refused)

  @doc "The event names a host has to hand over."
  def events, do: @events

  @doc """
  Runs one of them for `user`. A row that is not theirs, or already gone, is a
  no-op rather than an error — the card may be a moment behind the row.
  """
  def act(%User{} = user, event, %{"id" => id}) when event in @events do
    case Pending.get(user, id) do
      nil -> :ok
      pending -> run(event, pending)
    end

    :ok
  end

  defp run("cancel-pending-post", pending), do: Pending.cancel(pending)
  defp run("publish-without-refused", pending), do: Pending.publish_without_refused(pending)
end
