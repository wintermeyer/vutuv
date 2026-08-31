defmodule VutuvWeb.FediverseAccountLive do
  @moduledoc """
  The page for an account on another network
  (`/system/fediverse/account/:id`, issue #1162).

  Every remote handle vutuv shows — a reaction chip, a remote reply card, a
  remote post in the feed — used to link straight out of the site. So deciding
  to follow somebody you saw react to your own post meant leaving, finding them,
  coming back and pasting their address into a settings page. This is that
  detour removed: the handle now lands here, where the account is what it is and
  the follow button is right there.

  **It is not a mirror profile.** It is a follow surface plus a preview: the
  name, the address, the self-description, the follow state, and the posts we
  already hold — capped, newest first — with "View the original" one click away.
  Somebody's full history stays their own server's job. Nothing is fetched on
  view: opening this page makes no request to anybody, so a link to it can never
  be used to make vutuv poke a third-party server.

  Two things it can show that the origin profile cannot, which is why it is
  worth having at all: a post its author addressed to their followers is
  readable here by a member whose own follow is accepted (logged out on that
  server they would see nothing of it), and the cached posts are the "what do
  they actually post" preview that decides the follow.

  **Signed-in only and `noindex`.** The page is assembled from things other
  people wrote on other servers, so it is neither ours to publish nor useful to
  a crawler; the route carries the header, `on_mount` carries the login.

  Keyed by the **row id**, never by a URI: a page that took an address would be
  an open-ended "go and fetch this" surface. Reaching an account we do not know
  yet goes the other way round — the lookup box below resolves the address
  first, deliberately as an event and not as a GET.

  The follow box, the refusal panel and the wording of every refusal are the
  ones `/settings/fediverse/following` uses (`VutuvWeb.FediverseComponents`):
  two ways into one act, described once.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.FediverseComponents
  import VutuvWeb.PostComponents

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.RemotePostActions

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  # And a picture on any of the cards appears the moment the AI gate releases it
  # (issue #1801). One line, no handler: `@images` is the map keyed by post id.
  on_mount({VutuvWeb.Live.RemoteImages, :assigns})

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Fediverse.get_remote_account(id) do
      %RemoteAccount{} = account ->
        viewer = socket.assigns.current_user

        {:ok,
         socket
         |> assign(:address, "")
         |> assign(:error, nil)
         |> assign(:account, account)
         # Named as what it is: the tab, the bookmark and the history entry all
         # outlive the page, and a bare name there is indistinguishable from a
         # vutuv profile.
         |> assign(
           :page_title,
           gettext("%{name} (another network)", name: RemoteAccount.label(account))
         )
         |> assign(:blocked_reason, Fediverse.follow_refusal(viewer))
         |> assign(:follow, Fediverse.remote_follow_for(viewer, account))
         |> load_posts()}

      _ ->
        {:ok, InitAssigns.not_found(socket, ~p"/feed")}
    end
  end

  # The cached posts, and whether the cap left any out. Only an unfollow can
  # move this: the copies exist because somebody here follows the author, and
  # `unfollow_remote/2` deletes them the moment nobody does.
  defp load_posts(socket) do
    viewer = socket.assigns.current_user
    {posts, more?} = Fediverse.account_posts(socket.assigns.account, viewer)
    posts = Fediverse.with_quotes(posts)
    ids = Enum.map(posts, & &1.id)

    socket
    |> assign(:posts, posts)
    |> assign(:images, Fediverse.list_remote_images(ids))
    # Which of them the reader already likes (issue #1164), read once for the
    # page. Unlike the feed this page holds its posts in a plain assign, so a
    # set beside them redraws every card on a toggle, which is what we want.
    |> assign(:marks, Fediverse.mark_lookup(posts, viewer))
    |> assign(:more?, more?)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("follow", _params, socket) do
    account = socket.assigns.account

    case Fediverse.follow_remote_account(socket.assigns.current_user, account) do
      {:ok, follow} ->
        # Only the button changes. A fresh follow is "requested", so no
        # followers-only post opens until the other server answers, and there is
        # nothing to reload.
        {:noreply,
         socket
         |> put_flash(:info, follow_message(follow))
         |> assign(:follow, follow)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal_message(reason))}
    end
  end

  def handle_event("unfollow", _params, socket) do
    follow = socket.assigns.follow

    if follow, do: Fediverse.unfollow_remote(socket.assigns.current_user, follow.id)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Unfollowed."))
     |> assign(:follow, nil)
     |> load_posts()}
  end

  # Mute and **unmute**. The feed's card menu can mute an account, and muting it
  # takes its posts out of the feed — which takes the menu with them, so until
  # this control existed the flash promising "you still follow them" described a
  # door that only opened one way. This page is where a muted account can still
  # be reached, so this is where the way back belongs.
  def handle_event("toggle-mute", _params, socket) do
    account = socket.assigns.account
    viewer = socket.assigns.current_user
    muted? = not socket.assigns.follow.muted

    :ok = Fediverse.set_remote_follow_mute(viewer, account.id, muted?)

    {:noreply,
     socket
     |> put_flash(:info, mute_message(muted?))
     |> assign(:follow, Fediverse.remote_follow_for(viewer, account))}
  end

  # The two controls a cached post carries, handled here as well as on the feed:
  # this page shows public posts of accounts the viewer does **not** follow (they
  # are cached because somebody else does), so it is the only place those will
  # ever be seen — and a card nobody can report is not a card, it is a display.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &load_posts/1)
  end

  # The heart (issue #1164): the local marker plus a signed `Like` to this
  # account's own inbox. Only the reader's own state changes — there is no
  # count on the card, because the real one lives on their server.
  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.mute(socket, account_id, &reread_follow/1)
  end

  # The card menu's Unfollow, which is this page's own button by another route —
  # so it ends in the same state: no follow, and the cached posts gone with it.
  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.unfollow(socket, account_id, fn socket ->
      socket |> assign(:follow, nil) |> load_posts()
    end)
  end

  # The lookup box: an address in, that account's page out. Resolving is an
  # outbound request, so it is an event a member triggers on purpose, never
  # something a URL does on arrival.
  def handle_event("look-up", %{"address" => address}, socket) do
    case Fediverse.resolve_remote_account(socket.assigns.current_user, address) do
      {:ok, account} ->
        {:noreply, push_navigate(socket, to: ~p"/system/fediverse/account/#{account.id}")}

      {:error, :local_account} ->
        # An address on one of this vutuv's own hosts already HAS a page here,
        # so go to it instead of explaining why we will not fetch ourselves: a
        # member's is their profile, a tag actor's (`@php@tags.<host>`, issue
        # #1330) is the tag page. The refusal stays for a name nothing here
        # answers to.
        local_destination(socket, address)

      {:error, reason} ->
        {:noreply, socket |> assign(:address, address) |> assign(:error, reason)}
    end
  end

  def handle_event("typing", %{"address" => address}, socket) do
    {:noreply, socket |> assign(:address, address) |> assign(:error, nil)}
  end

  # Where an address on one of our own hosts really points (defined below the
  # last `handle_event/3` clause so the group is not split). Members are asked
  # first: they and the tag actors live on different hosts, so at most one can
  # answer, and the order only decides which lookup is spent.
  defp local_destination(socket, address) do
    cond do
      member = Fediverse.local_member_for_address(address) ->
        {:noreply, push_navigate(socket, to: ~p"/#{member.username}")}

      tag = Fediverse.local_tag_for_address(address) ->
        {:noreply, push_navigate(socket, to: ~p"/tags/#{tag.slug}")}

      true ->
        {:noreply, socket |> assign(:address, address) |> assign(:error, :local_account)}
    end
  end

  # Every act on a card here, one shape (below the last `handle_event/3` clause,
  # so the group is not split): the heart and the reshare, in both directions.
  # The marker sets are re-read rather than nudged, so what the page draws is
  # what the database says — a second tab that liked the same post is then not
  # contradicted by this one. `:flash` is an `{outcome, message}` the act
  # announces itself with, and only when that outcome really came back.
  defp mute_message(true),
    do: gettext("Muted. You still follow them; their posts leave your feed.")

  defp mute_message(false), do: gettext("Unmuted. Their posts are back in your feed.")

  # What the page draws is what the database says, so the follow is re-read
  # rather than nudged — a second tab that changed it is then not contradicted.
  defp reread_follow(socket) do
    assign(
      socket,
      :follow,
      Fediverse.remote_follow_for(socket.assigns.current_user, socket.assigns.account)
    )
  end

  # Why the Posts card is empty, which is a different sentence in each case. The
  # flat "nobody here follows this account" was simply false for a member with a
  # requested follow and only followers-only posts cached: we hold them and were
  # telling them we hold nothing.
  defp no_posts_message(nil),
    do:
      gettext(
        "Nothing here. vutuv only keeps an account's posts while somebody here follows it, and this page never fetches any."
      )

  defp no_posts_message(%{state: "accepted"}),
    do: gettext("Nothing cached yet. Their posts appear here as they publish them.")

  defp no_posts_message(%{}),
    do:
      gettext(
        "Waiting for that server to accept your follow. Posts they addressed to their followers appear once it does."
      )

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fediverse-account" class="mx-auto max-w-2xl space-y-6 py-6">
      <.card>
        <div class="flex items-start gap-4">
          <.remote_avatar
            initials={name_initials(RemoteAccount.display_name(@account) || @account.handle)}
            src={RemoteAccount.avatar_url(@account)}
            size="lg"
          />

          <div class="min-w-0 flex-1">
            <%!-- Before the name, not after the handle: the round tile, the
            bold name and the muted line under it are exactly a member profile
            header, and a reader must know which world they are looking at
            before they read who it is. --%>
            <.section_title>{gettext("Account on another network")}</.section_title>
            <h1 class="mt-0.5 break-words text-xl font-bold text-slate-900 dark:text-white">
              {RemoteAccount.label(@account)}
            </h1>
            <p class="mb-0 mt-0.5 text-sm text-slate-600 dark:text-slate-400">
              <%!-- The address links out: this page is the follow surface, that
              one is where they actually live, and the reader must always be one
              click from the real thing. --%>
              <a
                href={@account.actor_uri}
                target="_blank"
                rel="nofollow noopener noreferrer"
                data-remote-origin
                class="break-all font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              >
                {RemoteAccount.display_handle(@account)}
              </a>
              · {gettext("From another network")}
            </p>
          </div>
        </div>

        <%!-- A self-description is remote text and may be 10,000 characters. Run
        whole it would be some 400 lines on a phone, with Follow, the posts and
        the lookup box all several screens below it. So it is clamped with a lid,
        the same shape every other long remote text on the site wears. --%>
        <%!-- Whether the toggle is offered at all is decided by measuring, not
        by the server: the cut is `-webkit-line-clamp`, so how many lines this
        description really takes depends on the reader's window and font and is
        not knowable here. The measuring already exists for post previews
        (`revealPreviewClamp` in app.js, hook and `data-clamp-body` below), and
        it answers on the wrapper: `is-measured` once it has looked,
        `is-clamped` when something is genuinely hidden.

        That pair, rather than `is-clamped` alone, is what keeps this working
        with JavaScript off. Unmeasured means the toggle shows, which is exactly
        today's behaviour, so the enhancement can only ever take away a control
        that does nothing — never the one that does something. --%>
        <details
          :if={@account.summary}
          id="remote-summary"
          phx-hook="PostPreviewClamp"
          data-remote-summary
          class="group mt-4"
        >
          <%!-- `cursor` and the toggle's `display` both live in components.css
          (`[data-remote-summary]`), so each has ONE owner. A Tailwind display
          utility here beside a state rule is the cascade conflict that made
          "Read more" show on every post (issue #880). --%>
          <summary class="list-none">
            <span data-remote-summary-toggle>
              <span class="mt-1 inline-flex min-h-10 items-center text-xs font-medium text-brand-600 group-open:hidden dark:text-brand-400">
                {gettext("Show the whole description")}
              </span>
              <span class="mt-1 hidden min-h-10 items-center text-xs font-medium text-brand-600 group-open:inline-flex dark:text-brand-400">
                {gettext("Show less")}
              </span>
            </span>
            <p
              data-clamp-body
              class="post-clamp mb-0 whitespace-pre-line break-words text-sm leading-relaxed text-slate-700 group-open:hidden dark:text-slate-300"
            >
              {@account.summary}
            </p>
          </summary>
          <p class="mb-0 whitespace-pre-line break-words text-sm leading-relaxed text-slate-700 dark:text-slate-300">
            {@account.summary}
          </p>
        </details>

        <div class="mt-5">
          <%= if @blocked_reason do %>
            <.follow_refusal_panel id="cannot-follow" reason={@blocked_reason} />
          <% else %>
            <%!-- One block for both follow states: what differs is the badge's
                  word and colour and the button's label, and those come from
                  the sibling page, so "Requested" cannot mean two things. --%>
            <div :if={@follow} class="flex flex-wrap items-center gap-3">
              <span
                data-follow-state={@follow.state}
                class={[
                  "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ring-1",
                  follow_state_class(@follow)
                ]}
              >
                {follow_state_label(@follow)}
              </span>
              <span
                :if={@follow.muted}
                data-follow-muted
                class="inline-flex rounded-full bg-slate-100 px-2 py-0.5 text-xs font-semibold text-slate-700 ring-1 ring-slate-200 dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-700"
              >
                {gettext("Muted")}
              </span>
              <.button id="unfollow" variant="secondary" phx-click="unfollow">
                {end_follow_label(@follow)}
              </.button>
              <%!-- The way back out of a mute. Muting from the feed removes the
              account's posts, and with them the menu that muted it, so without
              this the flash's "you still follow them" led nowhere. --%>
              <.button id="toggle-mute" variant="ghost" phx-click="toggle-mute">
                <%= if @follow.muted do %>
                  {gettext("Unmute")}
                <% else %>
                  {gettext("Mute")}
                <% end %>
              </.button>
            </div>

            <.button :if={is_nil(@follow)} id="follow" phx-click="follow">
              {gettext("Follow")}
            </.button>
          <% end %>
        </div>
      </.card>

      <.card>
        <.section_title>{gettext("Posts")}</.section_title>

        <%= if @posts == [] do %>
          <%!-- Why it is empty, which is a different sentence per follow state:
          "nobody here follows this account" is simply untrue for a member whose
          own follow is only requested. --%>
          <p class="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-400" id="no-posts">
            {no_posts_message(@follow)}
          </p>
        <% else %>
          <div class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
            <%!-- The real viewer, so the card keeps its ⋯ menu. This page shows
                  public posts of accounts the reader does NOT follow (cached
                  because somebody else does), so it is the only place they will
                  ever see them — a card nobody can report is a display, not a
                  card. The account is stitched in rather than preloaded per row:
                  it is the one account, already in hand. --%>
            <div :for={post <- @posts} class="py-4 first:pt-0 last:pb-0">
              <.remote_post_card
            live?
                remote_post={%{post | remote_account: @account}}
                images={Map.get(@images, post.id, [])}
                marks={@marks.(post)}
                following?={@follow != nil}
                viewer={@current_user}
              />
            </div>
          </div>

          <p :if={@more?} class="mt-3 text-xs text-slate-600 dark:text-slate-400">
            {gettext("The most recent %{count} are shown. The rest are on their own server.",
              count: delimited_count(length(@posts))
            )}
          </p>
        <% end %>

        <%!-- In EVERY state, not only when the cap cut something: for an account
        nobody follows this card is otherwise a dead end, and this link is the
        page's own thesis — a preview here, the whole person over there. --%>
        <.card_footer_link href={@account.actor_uri}>
          {gettext("View their full profile on %{host}", host: @account.host)}
        </.card_footer_link>
      </.card>

      <.card>
        <.section_title>{gettext("Look up another account")}</.section_title>
        <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext("Paste an address from Mastodon and friends to open its page here.")}
        </p>

        <.address_form
          id="lookup"
          address={@address}
          error={@error}
          event="look-up"
          submit={gettext("Look up")}
          variant="secondary"
          class="mt-3"
        />

        <.card_footer_link href={~p"/settings/fediverse/following"}>
          {gettext("Accounts you follow elsewhere")}
        </.card_footer_link>
      </.card>
    </div>
    """
  end
end
