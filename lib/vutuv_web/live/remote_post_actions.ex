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

  A surface that renders the menu **must** handle every one of its events — an
  unhandled `phx-click` takes the LiveView down, so a card whose host forgot one
  is a button that kills the page.
  """

  use Gettext, backend: VutuvWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Mutes
  alias Vutuv.Tags.ExternalPosts
  alias VutuvWeb.MuteMessages

  # Nobody is not an actor. Every act here names the reader — report, mute,
  # unfollow — and the card renders the menu for a signed-in one only, so an
  # anonymous socket arriving at one of these is a crafted client and not a
  # member. Until issue #2164 each act carried that straight into a context
  # function with a single `%User{}` head, where it raised and took the page
  # down with it — and a tag timeline is a page anybody can open. One clause for
  # all six, in the module that owns the events, rather than a nil clause per
  # context weakening six honest heads.
  defp with_viewer(socket, act) do
    case socket.assigns[:current_user] do
      %User{} = viewer -> act.(viewer)
      _nobody -> {:noreply, socket}
    end
  end

  @doc """
  Handles a `"report-remote-post"` event for the cached post `id`, returning the
  `{:noreply, socket}` its `handle_event/3` clause can return directly.

  `on_removed` takes the socket and returns it, and runs wherever the card has
  to leave the page.
  """
  def report(socket, id, on_removed) when is_function(on_removed, 1) do
    with_viewer(socket, fn viewer ->
      id
      |> Fediverse.report_remote_post(viewer)
      |> reported(socket, on_removed)
    end)
  end

  @doc """
  The same for a `"report-external-post"` event — a post a followed tag brought
  back from another server's public tag timeline (issue #2127).

  Same three answers, and **sentences of its own**: this act can take several
  copies where its sibling takes the one row that exists. Promising a member a
  single deleted copy while the twin stood two cards further down is the defect
  issue #2164 exists for — and promising every copy where only one goes would be
  the same defect with the words the other way round, so the receipt is the
  scope the context answers with rather than a wording chosen here. How far a
  report reaches, and why that depends on which server filed the row, is
  `Vutuv.Tags.ExternalPosts.report/2`.
  """
  def report_external(socket, id, on_removed) when is_function(on_removed, 1) do
    with_viewer(socket, fn viewer ->
      id
      |> ExternalPosts.report(viewer)
      |> reported(socket, on_removed)
    end)
  end

  # The answer, whichever copy it was about. The cached post's sibling takes the
  # one row that exists and says so; this one is handed the scope its context
  # acted on, so the receipt cannot promise more or less than happened.
  defp reported(:ok, socket, on_removed),
    do: thanked(socket, gettext("Thank you. Our copy was deleted right away."), on_removed)

  defp reported({:ok, :every_copy}, socket, on_removed),
    do: thanked(socket, gettext("Thank you. Every copy on this vutuv is gone."), on_removed)

  defp reported({:ok, :this_copy}, socket, on_removed),
    do:
      thanked(
        socket,
        gettext("Thank you. This copy is gone for everyone on this vutuv."),
        on_removed
      )

  defp reported({:error, :rate_limited}, socket, _on_removed) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("You have reported a lot today. Please try again tomorrow.")
     )}
  end

  defp reported({:error, :not_found}, socket, on_removed),
    do: {:noreply, on_removed.(socket)}

  defp thanked(socket, message, on_removed) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> on_removed.()}
  end

  @doc """
  Handles a `"mute-remote-account"` event for the account `id`: the private,
  reversible "not this account". Its posts leave the feed however they arrive —
  its own, a boost, a member's reshare — so `on_muted` is where a surface takes
  the rows away.

  Works whether or not the reader follows the account: the mute is
  a row about the account, and where there IS a follow `Vutuv.Mutes` sets its
  flag too, so the account page and the following list agree with this menu. The
  sentence differs for the same reason — telling somebody they still follow an
  account they never followed is a confusing thing to read.
  """
  def mute(socket, account_id, on_muted) when is_function(on_muted, 1) do
    with_viewer(socket, fn viewer ->
      case Mutes.target("remote_account", account_id) do
        nil ->
          {:noreply, on_muted.(socket)}

        account ->
          following? = Fediverse.remote_follow_for(viewer, account) != nil
          {:ok, _mute} = Mutes.mute(viewer, account, :all)

          {:noreply,
           socket
           |> put_flash(:info, muted_message(following?))
           |> on_muted.()}
      end
    end)
  end

  @doc """
  Handles a `"mute-remote-reposts"` event for the account `id`: keep the
  account, drop what it passes on.

  The other half of the same complaint, and the one that names an account the
  reader follows on purpose — a followed account that boosts the same stranger
  every day is not an account they want to lose.
  """
  def mute_reposts(socket, account_id, on_muted),
    do: mute_at(socket, account_id, :reposts, on_muted)

  @doc """
  Handles a `"mute-remote-reposts-of"` event for the account `id`: the same
  complaint read from the **author's** side — whatever anybody passes on of this
  account stays out, while the account itself keeps reaching whoever follows it.

  This is the one the boost banner leaves a reader wanting: the account they do
  not want to meet is the one being handed around, and switching the booster off
  only holds until the next member boosts the very same account.
  """
  def mute_reposts_of(socket, account_id, on_muted),
    do: mute_at(socket, account_id, :reposts_of, on_muted)

  # Both narrow scopes are the same act about a different side of the same card,
  # so they are one function with the scope passed in: written twice, the copies
  # differed by an atom and a sentence, which is two places for the next scope
  # to be forgotten in.
  defp mute_at(socket, account_id, scope, on_muted) when is_function(on_muted, 1) do
    with_viewer(socket, fn viewer ->
      case Mutes.target("remote_account", account_id) do
        nil ->
          {:noreply, on_muted.(socket)}

        account ->
          {:ok, _mute} = Mutes.mute(viewer, account, scope)

          {:noreply,
           socket
           |> put_flash(:info, MuteMessages.flash(scope))
           |> on_muted.()}
      end
    end)
  end

  defp muted_message(true),
    do: gettext("Muted. You still follow them; their posts leave your feed.")

  defp muted_message(_not_following), do: MuteMessages.flash(:all)

  @doc """
  Handles an `"unfollow-remote-account"` event for the account `id`: the member
  takes the follow back, wherever they are reading (the card asks first).

  The cached posts existed because somebody here follows the author, so
  `Vutuv.Fediverse.unfollow_remote/2` deletes them when nobody does any more —
  which is why `on_removed` runs on both arms: the rows this member is looking
  at may be gone from the database by the time it returns.
  """
  def unfollow(socket, account_id, on_removed) when is_function(on_removed, 1) do
    with_viewer(socket, fn viewer ->
      case Fediverse.unfollow_remote_account(viewer, account_id) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Unfollowed. Their posts leave your feed."))
           |> on_removed.()}

        {:error, :not_found} ->
          {:noreply, on_removed.(socket)}
      end
    end)
  end
end
