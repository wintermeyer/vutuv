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

  It shows the **origin's** own like and repost figures beside the reader's own
  state (issue #1283). Those are asked for in the background
  (`Vutuv.Fediverse.CountsRefresher`) and arrive here two ways: on the first
  render from the stored row, and afterwards through a `send_update/3` from
  whichever host LiveView is on screen — the bar cannot subscribe for itself,
  since a LiveComponent has no process of its own, so `VutuvWeb.Live.RemoteCounts`
  listens once per page and forwards by component id.

  A press moves the figure at once, before any server confirms it. We deliver the
  `Like` and only learn what the origin did with it on the next ask, so a still
  number would read as the press having done nothing; the stored figure is nudged
  by one on the same path (`Vutuv.Fediverse`), which is why the change survives a
  reload rather than living in this socket.

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

  @doc """
  The DOM id one of these bars gets, from the kind and id of what it acts on
  (the two words `Vutuv.Fediverse.subject_kind/1` answers in).

  Owned here because two sides have to agree on it exactly: the card that
  renders the bar, and `VutuvWeb.Live.RemoteCounts`, which addresses a
  `send_update/2` at it when the origin's figures move. A drift between them is
  silent — LiveView logs an unknown component id and moves on — so there is one
  function rather than two string interpolations.
  """
  def dom_id(:note, id), do: "remote-actions-note-#{id}"
  def dom_id(:remote_post, id), do: "remote-actions-post-#{id}"

  # The origin's figures moved while this page was open. Its own clause, because
  # such an update carries nothing else — no subject, no viewer — and must not
  # go looking for them.
  @impl true
  def update(%{counts: counts}, socket), do: {:ok, assign(socket, :counts, counts)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:subject, assigns.subject)
     |> assign(:viewer, assigns[:viewer])
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:notice_path, fn -> nil end)
     # `assign_new` like the marks below: a host re-render must not undo the
     # figure this bar has already nudged for the reader's own press.
     |> assign_new(:counts, fn -> Fediverse.counts(assigns.subject) end)
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
         |> assign(:notice_path, nil)
         |> assign(:marks, Map.put(marks, flag(act), not on?))
         |> assign(:counts, moved(socket.assigns.counts, act, outcome))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason, subject)}
    end
  end

  # A refusal, and for the one a member can do something about, the way there
  # (issue #1349). A sentence that names a setting and then leaves them to find
  # it is how "you do not take part in the Fediverse" turned into "vutuv does not
  # know who I am" in the report: nothing on the page led anywhere, so logging
  # out and back in was the only thing left to try. Every other reason is a
  # statement about this act with nowhere to send anybody.
  defp refusal(socket, reason, subject) do
    socket
    |> assign(:notice, like_refusal_message(reason, subject_kind(subject)))
    |> assign(:notice_path, if(reason == :not_federating, do: ~p"/settings/fediverse"))
  end

  # The reader's own act, on the figure in front of them. Only for an act that
  # really wrote something (`:already` is a second tab, and it moved nothing),
  # only for the two acts a server out there counts, and never onto a figure we
  # do not have — a `nil` means the origin does not serve that collection, and
  # turning it into a `1` would invent a total.
  defp moved(counts, "like", outcome) when outcome in [:liked, :unliked],
    do: Map.update!(counts, :likes, &step(&1, outcome == :liked))

  defp moved(counts, "repost", outcome) when outcome in [:reposted, :unreposted],
    do: Map.update!(counts, :shares, &step(&1, outcome == :reposted))

  defp moved(counts, _act, _outcome), do: counts

  defp step(nil, _up?), do: nil
  defp step(count, true), do: count + 1
  defp step(count, false), do: max(count - 1, 0)

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
    # The page the sentence names, as a link in the words that name it (issue
    # #1349). Split out of the translation rather than matched in it, so a `.po`
    # slip cannot 500 the feed; a notice without the marker (every other
    # refusal, and the reshare confirmation) comes back whole in `notice_pre`
    # and renders exactly as before.
    {notice_pre, notice_post} = split_marker(assigns.notice || "", "{settings}")

    assigns =
      assigns
      |> assign(:offer, offered_acts(assigns.subject))
      |> assign(:notice_pre, notice_pre)
      |> assign(:notice_post, notice_post)

    ~H"""
    <div>
      <.remote_actions
        target={@myself}
        subject_id={@subject.id}
        viewer={@viewer}
        liked?={@marks.liked?}
        reposted?={@marks.reposted?}
        bookmarked?={@marks.bookmarked?}
        likes={@counts.likes}
        shares={@counts.shares}
        like?={@offer.like?}
        reply_to={@offer.reply_to}
        repost?={@offer.repost?}
      />
      <%!-- Beside the control that refused, in the reader's own words. The one
      refusal a member can act on says what to do about it; the rest say only
      that it did not work (`like_refusal_message/2`). `text-sm`, not the
      quieter `text-xs` a confirmation would take: this line is the whole answer
      for the reader who gets it, and it carries the link they need to hit. --%>
      <p
        :if={@notice}
        role="status"
        data-remote-notice
        class="mt-1 text-sm text-slate-600 dark:text-slate-400"
      >
        {@notice_pre}<.link
          :if={@notice_path}
          href={@notice_path}
          data-remote-notice-link
          class="font-semibold text-brand-600 underline underline-offset-2 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >{gettext("Fediverse settings")}</.link>{@notice_post}
      </p>
    </div>
    """
  end
end
