defmodule VutuvWeb.PostLive.RemoteActionsComponent do
  @moduledoc """
  The action bar on a card from another network — a reply that arrived under a
  member's post or a cached post by a followed account — as an **in-process
  LiveComponent** (issues #1275 and #1276).

  It exists for the reason `VutuvWeb.PostLive.ActionsComponent` exists one card
  over, and it was built after the same complaint. Seven hosts render these
  cards (the feed, the permalink conversation, the account page, the URL lookup,
  the tag timeline, the two answering pages) and every act used to mean a fresh
  copy of the same `handle_event` clause in each of them — which is why the
  reply card had two acts while the post card had three, why the answering pages
  rendered buttons that would have crashed them, and why a dead controller page
  rendered buttons that silently did nothing. Adding the bookmark would have
  meant seven more copies.

  So the bar owns its own state and its own events. A host renders it and
  handles **nothing**; what it may hand in is the marks it already batched
  (`marks`), which the feed and the conversation do because they draw many cards
  at once. Without them the bar loads its own three point lookups, which is what
  the single-card pages want anyway.

  What it deliberately does not do is subscribe to anything. There is no live
  counter to tick: vutuv does not know how many people on other servers liked or
  reshared a thing, so this bar shows the reader's own state and nothing else
  (`remote_actions/1` says the same in the markup).

  A refusal is explained **here**, inline under the bar, rather than as a flash.
  Two of the hosts are embedded LiveViews whose flash never reaches the toast
  tray in the dead layout, so a `put_flash/3` would be swallowed on exactly the
  page where the reply card lives.
  """
  use VutuvWeb, :live_component

  import VutuvWeb.PostComponents, only: [remote_actions: 1, like_refusal_message: 2]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:subject, assigns.subject)
     |> assign(:viewer, assigns[:viewer])
     |> assign_new(:notice, fn -> nil end)
     # `assign_new`, like the local bar: the first pass takes what the host
     # batched (or loads its own), and later host re-renders keep the copy this
     # bar may have toggled since — re-applying a stale preload would undo the
     # reader's just-clicked state.
     |> assign_new(:marks, fn -> marks(assigns[:marks], assigns.subject, assigns[:viewer]) end)}
  end

  # The three flags, from what the host batched or from this bar's own lookups.
  defp marks(%{} = batched, _subject, _viewer), do: batched
  defp marks(_none, _subject, nil), do: %{liked?: false, reposted?: false, bookmarked?: false}

  defp marks(_none, subject, viewer) do
    %{
      liked?: marked?(Fediverse.liked_ids(viewer, subject), subject),
      reposted?: marked?(Fediverse.reposted_ids(viewer, subject), subject),
      bookmarked?: marked?(Fediverse.bookmarked_ids(viewer, subject), subject)
    }
  end

  defp marked?(ids, subject), do: MapSet.member?(ids, subject.id)

  @impl true
  def handle_event("toggle", %{"act" => act}, socket) do
    %{subject: subject, viewer: viewer, marks: marks} = socket.assigns
    on? = Map.fetch!(marks, flag(act))

    case Fediverse.toggle_engagement(viewer, subject, act, not on?) do
      {:ok, outcome} ->
        {:noreply,
         socket
         |> assign(:notice, confirmation(outcome))
         |> assign(:marks, Map.put(marks, flag(act), not on?))}

      {:error, reason} ->
        {:noreply, assign(socket, :notice, like_refusal_message(reason, subject_kind(subject)))}
    end
  end

  # Resharing is the one act that says something back. The heart and the
  # bookmark are their own confirmation — the glyph fills in and that IS what
  # happened — but a reshare's effect is elsewhere: it goes to people who follow
  # the reader here and out there, and their own feed does not show it back to
  # them, so a silent button leaves them unsure whether it worked. Only on the
  # act itself, never on the repeat that wrote nothing.
  defp confirmation(:reposted), do: gettext("Reposted. Your followers see it now.")
  defp confirmation(_outcome), do: nil

  defp flag("like"), do: :liked?
  defp flag("repost"), do: :reposted?
  defp flag("bookmark"), do: :bookmarked?

  defp subject_kind(%Note{}), do: :reply
  defp subject_kind(%RemotePost{}), do: :post

  # Which acts this subject can carry at all — a fact about the **subject**,
  # never about the reader: what a member may do is decided by the gates when
  # they press, and hiding a control would leave them no way to find out the
  # capability exists (issue #1070). What is answered here is narrower, whether
  # the act is possible for this thing in the first place:
  #
  #   * `like?` — a reply needs a stored inbox to deliver the `Like` to; one
  #     saved before issue #1070 has none, and a heart that could never leave
  #     the building is worse than no heart. A cached post always has its
  #     author's.
  #   * `reply_to` / `repost?` — public subjects only. An answer is a public
  #     vutuv post and a reshare is publishing, so passing on an audience its
  #     author narrowed is not ours to do.
  #
  # Bookmarking is absent because it is always possible: it stays here, sends
  # nothing, and asks nothing of anybody's standing. It lives on this side of
  # the house rather than in `Vutuv.Fediverse` because two thirds of it is a
  # route.
  defp offered_acts(%Note{} = note) do
    %{
      like?: Note.likeable?(note),
      reply_to: Note.public?(note) && ~p"/system/fediverse/reply/#{note.id}",
      repost?: Note.public?(note)
    }
  end

  defp offered_acts(%RemotePost{} = post) do
    open? = RemotePost.open?(post)

    %{
      like?: true,
      reply_to: open? && ~p"/system/fediverse/reply/post/#{post.id}",
      repost?: open?
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :offer, offered_acts(assigns.subject))

    ~H"""
    <div>
      <.remote_actions
        target={@myself}
        subject_id={@subject.id}
        viewer={@viewer}
        liked?={@marks.liked?}
        reposted?={@marks.reposted?}
        bookmarked?={@marks.bookmarked?}
        like?={@offer.like?}
        reply_to={@offer.reply_to}
        repost?={@offer.repost?}
      />
      <%!-- Beside the control that refused, in the reader's own words. The one
      refusal a member can act on says what to do about it; the rest say only
      that it did not work (`like_refusal_message/2`). --%>
      <p
        :if={@notice}
        role="status"
        data-remote-notice
        class="mt-1 text-xs text-slate-600 dark:text-slate-400"
      >
        {@notice}
      </p>
    </div>
    """
  end
end
