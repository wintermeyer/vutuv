defmodule VutuvWeb.FediverseLookupLive do
  @moduledoc """
  Look up a post on another network by its URL (`/system/fediverse/lookup`,
  issue #1211).

  ActivityPub pushes only what happens **after** a follow is accepted. Everything
  an account published before that never arrives, so there is no
  `fediverse_posts` row for it, nothing to reply to, like or reshare — and the
  account page deliberately fetches nothing on view. That left one very ordinary
  thing impossible: somebody reads a post out there, wants to answer it from
  their vutuv identity, and has nowhere to put the link.

  This is that box. A URL in, the post itself out, as the same remote card the
  feed and the account page render, with its full action bar. Nothing new is
  invented here: the fetch is the announce path's dereference chain
  (`Vutuv.Fediverse.look_up_post/2`) and the card is the shared one, so a
  looked-up post is a cached post like any other and the follow-up acts are the
  ones that already exist.

  Three deliberate shapes:

    * **The result renders inline.** No permalink of ours, no anchor on the
      account page: a copy of somebody else's post is not a page we publish. Its
      one link out is the card's own "View the original".
    * **Any account, followed or not.** Which is why the copy gets a hold
      (`Vutuv.Fediverse.PostLookup`) against the sweep that drops the posts of
      accounts nobody follows — and why this page offers the follow: somebody
      who came here for one post is exactly somebody deciding about its author.
    * **Nothing happens on arrival.** Resolving is an outbound request, so it is
      an event the member triggers on purpose; a `GET` of this URL asks nobody
      anything. A reconnect therefore re-mounts to the empty page with the
      pasted URL recovered in the form — pressing "Look up" again costs neither
      a request nor a slot of the budget, since the post is cached by then.

  Signed-in only and `noindex`, like the account page and for the same reason:
  it is assembled from what somebody else wrote on somebody else's server.

  This is no longer the only door: a post address pasted into **`/search`** is
  offered the same lookup, because that is where somebody with an address in the
  clipboard goes, and a page under `/system/` is not something anybody finds. The
  wording both surfaces need lives in `VutuvWeb.FediverseComponents`; what the
  search box does with a resolved post is send the reader to our copy's own page
  (`/system/fediverse/post/:id`) rather than growing a second result view.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.FediverseComponents
  import VutuvWeb.PostComponents

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Posts
  alias VutuvWeb.Live.RemotePostActions

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Look up a post from another network"))
     |> assign(:url, "")
     |> assign(:error, nil)
     |> assign(:refusal, Fediverse.lookup_refusal(socket.assigns.current_user))
     |> clear_result()}
  end

  defp clear_result(socket) do
    socket
    |> assign(:post, nil)
    |> assign(:images, [])
    |> assign(:follow, nil)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("look-up", %{"url" => url}, socket) do
    case Fediverse.look_up_post(socket.assigns.current_user, url) do
      {:ok, post} ->
        {:noreply, socket |> assign(:url, url) |> assign(:error, nil) |> load_result(post)}

      # A vutuv post: the reader wants its permalink, not a copy of it.
      {:local, post} ->
        {:noreply, push_navigate(socket, to: Posts.path(post))}

      # An account rather than a post. Not an error and not a dead end: the
      # follow box is one page over and takes exactly this string.
      {:account, address} ->
        {:noreply,
         push_navigate(socket, to: ~p"/settings/fediverse/following?address=#{address}")}

      {:error, reason} ->
        {:noreply, socket |> assign(:url, url) |> assign(:error, reason) |> clear_result()}
    end
  end

  # Typing again clears the last refusal, so the box is not still shouting about
  # a URL the member has since corrected.
  def handle_event("typing", %{"url" => url}, socket) do
    {:noreply, socket |> assign(:url, url) |> assign(:error, nil)}
  end

  # The card is reportable here like everywhere else. It matters more here than
  # anywhere, in fact: this page is how a post nobody here follows the author of
  # gets into the installation at all, so the member who fetched it is the only
  # person in a position to say it should not have been.
  def handle_event("report-remote-post", _params, %{assigns: %{post: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("report-remote-post", _params, socket) do
    RemotePostActions.report(socket, socket.assigns.post.id, &clear_result/1)
  end

  # The other two acts the card's ⋯ menu offers, which this page renders only
  # for an account the member really follows. Both re-read the follow rather
  # than nudging it, like everything else here.
  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.mute(socket, account_id, &reread_follow/1)
  end

  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.unfollow(socket, account_id, &reread_follow/1)
  end

  def handle_event("follow", _params, %{assigns: %{post: nil}} = socket), do: {:noreply, socket}

  def handle_event("follow", _params, socket) do
    account = socket.assigns.post.remote_account

    case Fediverse.follow_remote_account(socket.assigns.current_user, account) do
      {:ok, follow} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Follow request sent to %{account}.", account: RemoteAccount.label(account))
         )
         |> assign(:follow, follow)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal_message(reason))}
    end
  end

  # Everything the card can do to the one post on this page, in one shape (below
  # the last `handle_event/3` clause, so the group is not split). The post is
  # re-read rather than nudged, so what the page draws is what the database
  # says. No `phx-value-id` is trusted: there is exactly one post here, it is the
  # one the socket already holds, and an act pushed at an empty page is nothing.

  defp reread_follow(%{assigns: %{post: nil}} = socket), do: socket

  defp reread_follow(socket) do
    assign(
      socket,
      :follow,
      Fediverse.remote_follow_for(socket.assigns.current_user, socket.assigns.post.remote_account)
    )
  end

  defp load_result(socket, post) do
    viewer = socket.assigns.current_user
    ids = [post.id]

    # No like/repost marks are read here: the card embeds `RemoteActionsComponent`,
    # which loads its own. Assigning them cost two queries per lookup for values
    # nothing rendered — and `clear_result/1` never set them, so no template
    # could have read them without crashing on the empty state.
    socket
    |> assign(:post, post)
    |> assign(:images, Map.get(Fediverse.list_remote_images(ids), post.id, []))
    |> assign(:follow, Fediverse.remote_follow_for(viewer, post.remote_account))
  end

  # Why this member cannot look anything up, and what is wrong with one pasted
  # URL, both live in `VutuvWeb.FediverseComponents` (imported above): the
  # search box offers the same lookup for a pasted address (issue #1211), and a
  # refusal explained in two places is a refusal explained twice, once badly.

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :refusal_link, assigns.refusal && lookup_refusal_link(assigns.refusal))

    ~H"""
    <div id="fediverse-lookup" class="mx-auto max-w-2xl space-y-6 py-6">
      <.card>
        <h1 class="text-xl font-bold text-slate-900 dark:text-white">
          {gettext("Look up a post from another network")}
        </h1>
        <p class="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext(
            "Paste the address of a post on Mastodon and friends. vutuv fetches it, shows it here, and you can answer, like or repost it as if it had arrived on its own."
          )}
        </p>

        <%= if @refusal do %>
          <div
            id="lookup-refusal"
            data-reason={@refusal}
            class="mt-4 rounded-lg bg-slate-50 p-4 text-sm leading-relaxed text-slate-700 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:text-slate-300 dark:ring-slate-700"
          >
            <h2 class="mb-2 text-base font-semibold text-slate-900 dark:text-white">
              {lookup_refusal_title(@refusal)}
            </h2>
            <p class="mb-0">{lookup_refusal_text(@refusal)}</p>
            <p :if={@refusal_link} class="mb-0 mt-3">
              <.link
                navigate={@refusal_link.path}
                id="lookup-refusal-link"
                class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              >
                {@refusal_link.label} ›
              </.link>
            </p>
          </div>
        <% else %>
          <form
            id="lookup-form"
            phx-submit="look-up"
            phx-change="typing"
            class="mt-4 flex flex-wrap items-end gap-3"
          >
            <div class="min-w-56 grow">
              <label for="lookup-url" class="sr-only">{gettext("Address of the post")}</label>
              <input
                type="text"
                name="url"
                id="lookup-url"
                value={@url}
                inputmode="url"
                autocomplete="off"
                autocapitalize="none"
                autocorrect="off"
                spellcheck="false"
                placeholder="https://server/@name/12345"
                aria-invalid={@error && "true"}
                aria-describedby={@error && "lookup-error"}
                class={input_class(@error != nil)}
              />
            </div>
            <.button type="submit" id="lookup-submit" class="w-full sm:w-auto">
              {gettext("Look up")}
            </.button>
          </form>

          <p
            :if={@error}
            id="lookup-error"
            role="alert"
            class="mt-2 text-sm font-medium text-red-700 dark:text-red-300"
          >
            {lookup_refusal_message(@error)}
          </p>
        <% end %>
      </.card>

      <%!-- The post itself, as the card every other surface renders it with.
      Mute and Unfollow are dropped unless the member really follows this
      account: this page reaches accounts they do not, and acting on a follow
      that does not exist is a control that does nothing under a flash that says
      it did. --%>
      <.card :if={@post} id="lookup-result">
        <%!-- Whole, not clamped: somebody who pasted this address came to read
        this post, and it is the only thing on the page. --%>
        <.remote_post_card
          live?
          mode={:full}
          remote_post={@post}
          images={@images}
          following?={@follow != nil}
          viewer={@current_user}
        />
      </.card>

      <%!-- Somebody who came here for one post is somebody deciding about its
      author, so the decision is offered right here rather than one page away.
      Following them also puts this post in the home feed at its own publication
      position, along with everything else they have written since. --%>
      <.card :if={@post}>
        <.section_title>{gettext("Who wrote this")}</.section_title>

        <div class="mt-3 flex flex-wrap items-center gap-3">
          <.remote_avatar
            initials={
              name_initials(
                RemoteAccount.display_name(@post.remote_account) || @post.remote_account.handle
              )
            }
            src={RemoteAccount.avatar_url(@post.remote_account)}
          />
          <div class="min-w-0 flex-1">
            <p class="mb-0 break-words font-semibold text-slate-900 dark:text-white">
              {RemoteAccount.label(@post.remote_account)}
            </p>
            <p class="mb-0 break-all text-sm text-slate-600 dark:text-slate-400">
              {RemoteAccount.display_handle(@post.remote_account)}
            </p>
          </div>

          <span
            :if={@follow}
            data-follow-state={@follow.state}
            class={[
              "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ring-1",
              follow_state_class(@follow)
            ]}
          >
            {follow_state_label(@follow)}
          </span>

          <.button :if={is_nil(@follow)} id="follow-author" phx-click="follow">
            {gettext("Follow")}
          </.button>
        </div>

        <.card_footer_link href={~p"/system/fediverse/account/#{@post.remote_account.id}"}>
          {gettext("Their account page here")}
        </.card_footer_link>
      </.card>

      <.card>
        <.section_title>{gettext("Related")}</.section_title>
        <div class="mt-2 space-y-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          <p class="mb-0">
            {gettext("Looking for an account rather than a single post?")}
            <.link
              navigate={~p"/settings/fediverse/following"}
              id="following-link"
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Accounts you follow elsewhere")} ›
            </.link>
          </p>
          <p class="mb-0">
            {gettext(
              "vutuv keeps a copy of a post you look up for the same six months every other post from another network gets, and its author's server is asked nothing else."
            )}
          </p>
        </div>
      </.card>
    </div>
    """
  end
end
