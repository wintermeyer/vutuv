defmodule VutuvWeb.FediversePostLive do
  @moduledoc """
  vutuv's copy of one post from another network (`/system/fediverse/post/:id`).

  Every card in the feed carries a timestamp, and on a member's post that stamp
  is the way to the post's own page. On a cached remote post it was plain text,
  so the one card in the timeline that a reader could not open, link, or come
  back to was the one from somewhere else. This is that page: the same card the
  feed draws, alone, with its action bar and its way on to the account.

  It is **our copy, not a republication**, and the difference is what the page is
  shaped by:

    * **Signed-in only and `noindex`**, like the account page and the lookup box
      next to it, and for the same reason — the content is somebody else's words
      from somebody else's server. So it has no agent-format siblings either,
      and `PostComponents` renders the stamp as a link only when the card has a
      viewer (an anonymous reader of a public tag timeline keeps the plain
      stamp instead of a link into a login wall).
    * **Readable, not merely present.** `Fediverse.remote_post_readable?/2` is
      the one gate every read-side surface shares, so a post its author
      addressed to their followers opens here for a member whose own follow was
      accepted and is a 404 for everybody else. Nothing about the row leaks
      through the refusal.
    * **Nothing is fetched on view.** Opening this URL makes no request to
      anybody: it renders the row we already hold, or it does not exist. The
      cached copy is also not ours to keep forever — the sweep drops it once
      nobody here follows the author, and a reported copy is deleted at once, so
      this page can go away while its link lives on. "View the original" on the
      card is the address that does not expire.

  The two card controls a host has to answer for are handled here as everywhere:
  the ⋯ menu's Report (which deletes the copy, so the page has nothing left to
  show and the reader is sent back to the feed) and Mute. The action bar owns
  its own events (`VutuvWeb.PostLive.RemoteActionsComponent`) and is handed no
  batched marks — one card, so its own three lookups are cheaper than a batch.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.RemotePostActions

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    viewer = socket.assigns.current_user
    post = Fediverse.get_remote_post(id)

    if post && Fediverse.remote_post_readable?(post, viewer) do
      {:ok, assign_post(socket, post, viewer)}
    else
      {:ok, InitAssigns.not_found(socket, ~p"/feed")}
    end
  end

  defp assign_post(socket, %RemotePost{} = post, viewer) do
    account = post.remote_account

    socket
    # Named for what it is, because the tab, the bookmark and the history entry
    # all outlive the page: a bare name there reads as a vutuv member's post.
    |> assign(
      :page_title,
      gettext("A post by %{name} (another network)", name: RemoteAccount.label(account))
    )
    |> assign(:remote_post, post)
    |> assign(:images, Map.get(Fediverse.list_remote_images([post.id]), post.id, []))
    # Whether the ⋯ menu offers Mute at all. This page is reachable for a public
    # post whose author the reader does not follow (it is cached because
    # somebody else does), and muting a follow that does not exist is a control
    # that does nothing behind a flash saying otherwise.
    |> assign(:follows?, not is_nil(Fediverse.remote_follow_for(viewer, account)))
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("report-remote-post", _params, socket) do
    # The copy this page is about is gone, so there is no page left to stay on.
    # The feed is where the card was met.
    RemotePostActions.report(
      socket,
      socket.assigns.remote_post.id,
      &push_navigate(&1, to: ~p"/feed")
    )
  end

  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    :ok = Fediverse.set_remote_follow_mute(socket.assigns.current_user, account_id, true)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Muted. You still follow them; their posts leave your feed."))
     |> assign(:follows?, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fediverse-post" class="mx-auto max-w-2xl space-y-6 py-6">
      <.card>
        <.section_title>{gettext("A post from another network")}</.section_title>
        <%!-- Said once, at the top: what a reader has in front of them is the
        copy this installation received, not the post itself. It is why the
        pictures, the counts and the "View the original" link below behave the
        way they do. --%>
        <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext(
            "This is vutuv's copy of a post published on %{host}. It is kept while somebody here follows its author.",
            host: @remote_post.remote_account.host
          )}
        </p>

        <div class="mt-4">
          <.remote_post_card
            live?
            remote_post={@remote_post}
            images={@images}
            viewer={@current_user}
            mute?={@follows?}
          />
        </div>

        <.card_footer_link href={~p"/system/fediverse/account/#{@remote_post.remote_account_id}"}>
          {gettext("More from %{name}", name: RemoteAccount.label(@remote_post.remote_account))}
        </.card_footer_link>
      </.card>
    </div>
    """
  end
end
