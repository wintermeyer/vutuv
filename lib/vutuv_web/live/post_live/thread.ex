defmodule VutuvWeb.PostLive.Thread do
  @moduledoc """
  The permalink page's conversation as an embedded LiveView, rendered by
  `VutuvWeb.PostController.render_post/4` via `live_render` (the profile's
  pattern: the controller keeps owning the URL, the agent-format negotiation
  and the page chrome; the socket owns the conversation card).

  A conversation does not stop at the site's edge in either direction. The post
  a member here answered on **another network** (issue #1165) is drawn above
  their answer, the card the feed draws — until this, a permalink to that answer
  showed a "Replying to @user@host" line and no way to what was being answered,
  which is the half of the exchange the reader arrived for.

  Replies written on **other networks** (issues #1069 and #1071) are woven into
  the same conversation as ordinary siblings, in time order, wearing their own
  card (`VutuvWeb.PostComponents.remote_reply_card/1`); `Vutuv.Fediverse.list_notes/2`
  scopes them to the viewer, so one addressed to the member alone never reaches
  anybody else's render. Their takedown controls are the `remove-remote-reply` /
  `report-remote-reply` events below, and their heart (issue #1270) the
  `like-remote-reply` / `unlike-remote-reply` pair — this host is why the card's
  acts render here and not on the answering page, which shows the same card
  read-only.

  It renders `Vutuv.Posts.thread_window/3`: a small conversation whole
  (`:all`, the issue #1006 page unchanged), a big one as a **window around
  the permalinked post** — the root pinned on top, a "Show N earlier posts"
  expander over the nearest ancestors, the post, the first chunk of its own
  reply subtree and a "Show N more replies" expander. The expanders are plain
  `phx-click` events that widen the server-side budgets and re-query; no
  custom JS. Before this, a long thread rendered every post — the 131-post
  test thread came to ~930 KB of HTML and one embedded action-bar LiveView
  **per card** (132 sockets per visitor).

  Inside this host the cards' action bars are the in-process
  `VutuvWeb.PostLive.ActionsComponent` (one process for the whole page). The
  thread subscribes to each *shown* post's counter topic itself and forwards
  `{:post_counters, …}` to the matching component, so the permalink keeps the
  live-ticking counters the per-card `Actions` LiveViews used to provide —
  bounded by the window size instead of the conversation size.

  Mounted off-router (embedded), so it applies the session locale and
  resolves the viewer from the cookie's `session_token` itself via
  `VutuvWeb.Live.InitAssigns.assign_embedded/2`, like the profile.
  """

  use Phoenix.LiveView

  import VutuvWeb.PostComponents,
    only: [post_card: 1, thread_conversation: 1, thread_window_conversation: 1]

  import VutuvWeb.UI, only: [card: 1, delimited_count: 1]

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.PostRewrites
  alias Vutuv.Posts
  alias Vutuv.Prefs
  alias Vutuv.Social
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Live.RemoteImages
  alias VutuvWeb.Live.RemotePostActions
  alias VutuvWeb.Live.RemoteReplyActions
  alias VutuvWeb.PostLive.ActionsComponent

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  # And a picture on the cached post drawn above an answer (issue #1165)
  # appears the moment there is something to show of it — the promise its
  # waiting tile prints here as on every other surface. The hook's `:assigns`
  # mode does not fit: those pictures ride the parent cards rather than an
  # `@images` assign, so this host takes the bare subscription and writes the
  # one `handle_info/2` that mode asks of it, below.
  on_mount(RemoteImages)

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    defaults = Posts.thread_window_defaults()

    socket =
      socket
      |> assign(:post_id, session["post_id"])
      |> assign(:auto_scroll?, session["auto_scroll"] != false)
      |> assign(:ancestor_budget, defaults.ancestors)
      |> assign(:reply_budget, defaults.replies)
      |> assign(:subscribed_ids, MapSet.new())
      |> assign(:notice, nil)
      # On-demand translations (issue #1462): per-card view state; a map
      # means this viewer gets the controls, nil means they do not.
      |> assign(:post_translations, PostTranslations.initial_map(socket.assigns.current_user))
      |> mount_window()

    {:ok, socket}
  end

  # The dead render computes the window and stashes it; the connected mount —
  # moments later, same authenticated viewer, same post — takes it and skips
  # re-running the same queries (`VutuvWeb.Live.MountHandoff`). Any miss
  # (anonymous viewer, expired, already consumed, a reconnect after a blip or
  # deploy) falls back to the plain full load, so the handoff is a fast path,
  # never a requirement. The expanders and the PubSub-driven re-windows keep
  # calling `load_window/1` directly — only the mount pair shares work.
  defp mount_window(socket) do
    viewer_id = socket.assigns.current_user && socket.assigns.current_user.id
    subject = {:thread, socket.assigns.post_id}

    if connected?(socket) do
      case MountHandoff.take(viewer_id, subject) do
        {:ok, payload} -> apply_handoff(socket, payload)
        :error -> load_window(socket)
      end
    else
      before_keys = Map.keys(socket.assigns)
      socket = load_window(socket)
      # Exactly the assigns load_window added — diffed, not listed, so an
      # assign added to load_window later rides the handoff automatically.
      MountHandoff.stash(viewer_id, subject, Map.drop(socket.assigns, before_keys))
      socket
    end
  end

  # Apply the dead render's assigns, then do the connected-only work the dead
  # pass deliberately left out: one counter subscription per shown card and
  # the remote replies' fire-and-forget freshness check — the same calls
  # load_window makes on a connected socket.
  defp apply_handoff(socket, %{window: nil} = payload), do: assign(socket, payload)

  defp apply_handoff(socket, payload) do
    payload.remote_replies |> Map.values() |> List.flatten() |> Fediverse.refresh_async()

    ids = payload.window |> window_posts() |> Enum.map(& &1.id)

    socket
    |> assign(payload)
    |> subscribe_shown(ids)
  end

  @impl true
  def handle_event("thread-earlier", _params, socket) do
    step = Posts.thread_window_defaults().ancestor_page

    {:noreply,
     socket
     |> assign(:ancestor_budget, socket.assigns.ancestor_budget + step)
     |> load_window()}
  end

  def handle_event("thread-more", _params, socket) do
    step = Posts.thread_window_defaults().reply_page

    {:noreply,
     socket
     |> assign(:reply_budget, socket.assigns.reply_budget + step)
     |> load_window()}
  end

  # The member takes a reply from another network off their own post, or
  # anybody who can see it marks it as not appropriate. Both delete at once
  # (`Vutuv.Fediverse`), which is the whole workflow — there is no case and no
  # freezer, because unlike a member's own post this is a cache of something
  # that still exists at its origin.
  def handle_event("remove-remote-reply", %{"id" => id}, socket) do
    {:noreply, take_down(socket, id, &RemoteReplyActions.remove/2)}
  end

  def handle_event("report-remote-reply", %{"id" => id}, socket) do
    {:noreply, take_down(socket, id, &RemoteReplyActions.report/2)}
  end

  # The ⋯ menu of the cached post an answer here answers (issue #1165). Report
  # deletes our copy, so the card has to leave; unfollowing may delete it too
  # (nobody here follows the author any more), so both re-window. Mute keeps it,
  # as it does on the cached post's own page: the reader asked to see less of
  # that account in their feed, not to read this exchange with its first half
  # missing.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &load_window/1)
  end

  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.mute(socket, account_id, & &1)
  end

  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.unfollow(socket, account_id, &load_window/1)
  end

  @impl true
  def handle_event("translate", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.request(socket.assigns.current_user, kind, id) do
      {:ok, key, state} ->
        {:noreply, update(socket, :post_translations, &Map.put(&1, key, state))}

      :denied ->
        {:noreply, socket}
    end
  end

  def handle_event("show-original", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.show_original(socket.assigns.post_translations, kind, id) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
    end
  end

  @impl true
  def handle_info({:translation_ready, %Vutuv.Translations.Translation{} = translation}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_ready(socket.assigns.post_translations, translation, viewer) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
    end
  end

  def handle_info({:translation_failed, key, target}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_failed(socket.assigns.post_translations, key, target, viewer) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
    end
  end

  def handle_info({:post_counters, %{post_id: post_id} = payload}, socket) do
    # This host holds the post-topic subscriptions for its cards; the matching
    # in-process bar applies the payload (`ActionBar.apply_counters/2`). The
    # id mirrors post_card's `actions_id` for entry-less thread nodes.
    send_update(ActionsComponent, id: "post-actions-#{post_id}", counters: payload)
    {:noreply, refresh_likers(socket, post_id, payload)}
  end

  def handle_info({:post_deleted, %{post_id: _}}, socket) do
    # A shown post vanished (the author deleted it mid-visit): re-window, so
    # the conversation heals instead of keeping a dead card.
    {:noreply, load_window(socket)}
  end

  # A photo on a shown post cleared the AI image scan (issue #1104). Re-window
  # so the picture takes the place of its placecard, and the author's
  # "checking your photos…" line counts down, with no reload. The subscription
  # is the per-shown-post one this host already holds.
  def handle_info({:post_images_settled, %{post_id: _}}, socket) do
    {:noreply, load_window(socket)}
  end

  # A picture of the cached post drawn above an answer landed, or cleared the
  # scan. `RemoteImages` speaks in feed entries, and the parents a feed entry
  # nests are exactly this map (`Vutuv.Posts.remote_parents/2` builds both), so
  # the page hands it an entry with nothing else on it and gets the timeline's
  # own two steps: the cheap "not mine" test every open page needs — they all
  # hear about every picture — and a re-read of that one card, rather than a
  # whole re-window for a picture that changes nothing else on the page.
  def handle_info({:remote_images_changed, %{remote_post_id: id}}, socket) do
    entry = %{remote_parents: socket.assigns.remote_parents}

    if RemoteImages.draws?(entry, id) do
      entry = RemoteImages.restate_entry(entry, id, RemoteImages.pictures(id))
      {:noreply, assign(socket, :remote_parents, entry.remote_parents)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp visible_focus(post_id, viewer) do
    with %Posts.Post{} = post <- Posts.get_post(post_id),
         true <- Posts.visible_to?(post, viewer) do
      post
    else
      _withheld_or_gone -> nil
    end
  end

  # (Re)computes the window for the current budgets and batches what the
  # cards need: engagement for every shown post's action bar and the viewer's
  # follow edges for the ⋯ menus' mute items — the way the feed does it.
  defp load_window(socket) do
    viewer = socket.assigns.current_user

    # The controller checked visibility once, for the request that rendered the
    # page. This session map is signed but not encrypted and lives for days, so
    # a socket joining with it has to be told again — a post narrowed or frozen
    # since then is as absent here as a deleted one.
    case visible_focus(socket.assigns.post_id, viewer) do
      nil ->
        # Deleted, or no longer this viewer's to see; the controller answers the
        # next full load.
        socket
        |> assign(:window, nil)
        |> assign(:focus, nil)
        |> assign(:likers, nil)
        |> assign(:remote_replies, %{})
        |> assign(:remote_parents, %{})
        |> assign(:note_marks, Fediverse.mark_lookup([], nil))

      post ->
        # The reader's per-author search-and-replace rules, over every card the
        # window draws — the same treatment the feed gives its rows.
        rewrites = PostRewrites.compile_for(viewer)

        window =
          post
          |> Posts.thread_window(viewer,
            ancestors: socket.assigns.ancestor_budget,
            replies: socket.assigns.reply_budget
          )
          |> rewrite_window(rewrites, viewer)

        posts = window_posts(window)
        ids = Enum.map(posts, & &1.id)

        follows =
          if viewer do
            posts
            |> Enum.map(& &1.user_id)
            |> Enum.uniq()
            |> Enum.reject(&(&1 == viewer.id))
            |> then(&Social.follow_edges(viewer.id, &1))
          else
            %{}
          end

        # Replies written on other networks under any post in the window
        # (issues #1069 and #1071), viewer-scoped by `list_notes/2` — a reply
        # addressed to the member alone never reaches anybody else's render.
        remote = ids |> Fediverse.list_notes(viewer) |> rewrite_notes(rewrites, viewer)

        # What this reader has already done with each of them — three batched
        # reads for the whole window rather than three per card, the way the
        # posts' engagement is batched above.
        note_marks = remote |> Map.values() |> List.flatten() |> Fediverse.mark_lookup(viewer)

        # The lazy freshness check (issue #1069): ask the origins of the stale
        # public ones whether they are still published there. Deliberately
        # fire-and-forget in a task, so a stranger's slow server can never hold
        # up this render, and only on connect, so the throwaway dead render
        # does not pay for it.
        if connected?(socket) do
          remote |> Map.values() |> List.flatten() |> Fediverse.refresh_async()
        end

        engagement = Posts.post_engagement_map(ids, viewer)

        socket
        |> assign(:window, window)
        |> assign(:focus, Enum.find(posts, &(&1.id == post.id)) || post)
        |> assign(:engagement, engagement)
        |> assign(:remote_parents, Posts.remote_parents(posts, viewer))
        |> assign(:likers, likers(post, viewer, engagement[post.id]))
        |> assign(:viewer_follows, follows)
        |> assign(:remote_replies, remote)
        |> assign(:note_marks, note_marks)
        |> subscribe_shown(ids)
    end
  end

  # The "Liked by" row of the permalinked post (issue #1233) — this page's post
  # and no other, so it is one small query per load, not one per card.
  #
  # `total` is the figure the like button itself shows (`Posts.shown_counts/1`,
  # so a favourite from another network counts like any other like): the row's
  # faces plus its `+N` therefore add up to exactly the number above them, and
  # a member who opted out of being named rides in the `+N` instead of
  # vanishing from the tally.
  #
  # The author sees the opted-out likers too (`include_hidden?`) — they were
  # named in the like notification at the time — and the row tells them that
  # what they are looking at is not what everybody else sees (`private?`).
  defp likers(post, viewer, engagement) do
    author? = viewer != nil and viewer.id == post.user_id
    users = Posts.post_likers(post.id, include_hidden?: author?)

    %{
      users: users,
      total: (engagement && Posts.shown_counts(engagement).likes) || length(users),
      # Members only: a page in the list (issue #1410) has no attribution
      # preference to have opted out of.
      private?:
        author? and
          Enum.any?(users, &(is_struct(&1, User) and not Prefs.get(&1, :like_attribution?)))
    }
  end

  # A like landed (or was withdrawn) on the post this page is about while it was
  # open: the counters payload re-renders the bar, so the faces under it have to
  # move with it or the row and the number would tell different stories. Only
  # for the focus post — a like on a reply leaves this row alone.
  defp refresh_likers(socket, post_id, payload) do
    focus = socket.assigns.focus

    if focus && focus.id == post_id do
      assign(socket, :likers, likers(focus, socket.assigns.current_user, payload))
    else
      socket
    end
  end

  # The outcome is shown as an inline notice above the conversation, not as a
  # toast: a refusal belongs next to the reply it is about. (An embedded
  # LiveView *can* toast — `LayoutHTML.embedded_flash/1` portals its flash into
  # the layout's tray — so this is a placement choice, not a constraint.)
  #
  # A successful takedown says so by the card vanishing, which is why it clears
  # the notice rather than setting one.
  # The page says nothing on success — the reply is gone from the conversation,
  # which is the answer — and shows the refusal in its own `:notice` assign
  # rather than a flash, this being a `live_render`ed child.
  defp take_down(socket, id, fun) do
    case fun.(id, socket.assigns.current_user) do
      {:ok, _done} -> socket |> assign(:notice, nil) |> load_window()
      {:error, nil} -> socket
      {:error, message} -> assign(socket, :notice, message)
    end
  end

  defp window_posts(%{mode: :all, posts: posts}), do: posts

  defp window_posts(%{mode: :window} = window) do
    List.wrap(window.root) ++ window.chain ++ window.subtree
  end

  # The window, and the replies from other networks keyed by the post they
  # answer, with the reader's rewrites applied. A no-op for the many readers
  # with no rules — which is also the only case with no viewer to name.
  defp rewrite_window(window, compiled, _viewer) when compiled == %{}, do: window

  defp rewrite_window(window, compiled, viewer),
    do: Posts.map_thread_window(window, &PostRewrites.rewrite(&1, compiled, viewer.id))

  defp rewrite_notes(notes, compiled, _viewer) when compiled == %{}, do: notes

  defp rewrite_notes(notes, compiled, viewer),
    do:
      Map.new(notes, fn {id, list} ->
        {id, PostRewrites.rewrite_all(list, compiled, viewer.id)}
      end)

  # One counter subscription per shown card, added as expanders reveal more —
  # bounded by the window, never the conversation.
  defp subscribe_shown(socket, ids) do
    if connected?(socket) do
      subscribed = socket.assigns.subscribed_ids
      fresh = ids |> MapSet.new() |> MapSet.difference(subscribed)
      Enum.each(fresh, &Posts.subscribe_post/1)
      assign(socket, :subscribed_ids, MapSet.union(subscribed, fresh))
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="post-thread-frame">
      <p
        :if={@notice}
        id="thread-notice"
        role="status"
        class="mb-3 rounded-lg bg-slate-100 px-3 py-2 text-sm text-slate-700 dark:bg-slate-800 dark:text-slate-200"
      >
        {@notice}
      </p>
      <%= cond do %>
        <% is_nil(@window) -> %>
          <div id="post-thread-gone"></div>
        <% @window.mode == :all and @window.total == 1 and @remote_replies == %{} and
             @remote_parents == %{} -> %>
          <%!-- No conversation at all: the post stands alone as its own card.
          The author's Edit/Delete live in the card's own ⋯ menu. A post with no
          vutuv replies but an answer from another network (issue #1069), or one
          that answers a post out there (issue #1165), is not this case — it
          falls through to the conversation below, which is what weaves the one
          in and draws the other above it. --%>
          <.post_card
            post={@focus}
            viewer={@current_user}
            viewer_follow={@viewer_follows[@focus.user_id]}
            engagement={@engagement[@focus.id]}
            likers={@likers}
            mode={:full}
            conn_or_socket={@socket}
            translations={@post_translations}
          />
        <% true -> %>
          <%!-- The conversation (issue #1006), rendered like a feed thread
          row: connector lines between the cards, the permalinked post the
          tinted full-mode card; with context above it, app.js scrolls it into
          view on arrival ([data-thread-scroll]). A big conversation opens as
          a window around the post and grows over the expanders. --%>
          <.card id="post-thread">
            <%= if @window.mode == :all do %>
              <.thread_conversation
                posts={@window.posts}
                focus_id={@focus.id}
                viewer={@current_user}
                viewer_follows={@viewer_follows}
                engagement={@engagement}
                remote_replies={@remote_replies}
                remote_parents={@remote_parents}
                note_marks={@note_marks}
                likers={@likers}
                auto_scroll?={@auto_scroll?}
                conn_or_socket={@socket}
                translations={@post_translations}
              />
            <% else %>
              <.thread_window_conversation
                window={@window}
                focus_id={@focus.id}
                viewer={@current_user}
                viewer_follows={@viewer_follows}
                engagement={@engagement}
                remote_replies={@remote_replies}
                remote_parents={@remote_parents}
                note_marks={@note_marks}
                likers={@likers}
                auto_scroll?={@auto_scroll?}
                conn_or_socket={@socket}
                translations={@post_translations}
              />
            <% end %>
          </.card>
          <p
            :if={@window.mode == :window and @window.rest > 0 and @window.root}
            class="mt-3 px-2 text-sm text-slate-600 dark:text-slate-400"
          >
            {gettext("This post is part of a conversation with %{formatted} posts.",
              formatted: delimited_count(@window.total)
            )}<span :if={@window.truncated?}>+</span>
            <.link
              href={Posts.path(@window.root)}
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              id="thread-from-start"
            >
              {gettext("Read it from the start")}
            </.link>
          </p>
      <% end %>
    </div>
    """
  end
end
