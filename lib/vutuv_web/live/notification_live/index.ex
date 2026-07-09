defmodule VutuvWeb.NotificationLive.Index do
  @moduledoc """
  Notifications page. The feed is real data derived at mount time by
  `Vutuv.Activity.notifications_page/2` from the event tables that already
  exist (followers, endorsements, mutual connections), so it reaches back to
  events from before this page existed. The first page renders on the **static**
  mount too (like the newsfeed), so the list is in the first HTTP paint instead
  of arriving a websocket round trip later (issue #919 - the page felt sluggish
  because the whole list only appeared after the socket connected). Older pages
  load on demand via the "Load more" button (cursor pagination, appended to the
  stream). On top of that it updates live: new events arrive over
  `Vutuv.Activity` (PubSub `"user:<id>"`) and are prepended in real time.
  Visiting the page persists the read marker and clears the unread bell badge in
  the shell. Items are a LiveView stream, so a long-lived session doesn't
  accumulate them in process memory.
  """
  use VutuvWeb, :live_view

  # The quoted post under a reply/like event is the shared read-only preview the
  # feed and profile use, so a referenced post reads the same everywhere.
  import VutuvWeb.PostComponents, only: [post_preview: 1]

  # Like the feed and messages: not a page for anonymous visitors —
  # redirect to /login instead of rendering an empty 200.
  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Activity
  alias Vutuv.Posts
  alias Vutuv.Posts.Post

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Activity.subscribe(user.id)
      Activity.mark_notifications_read(user.id)
      # Roll the quoted posts' Berlin-day stamps over at midnight without a reload.
      Vutuv.DayClock.subscribe()
    end

    # Load the first page on *both* the static and the connected mount (like the
    # newsfeed, VutuvWeb.PostLive.Feed) so the notifications are in the first
    # HTTP paint, not a websocket round trip late. The page is login-required, so
    # this static render carries no SEO / no-JS value on its own - it exists only
    # to make the load feel instant (issue #919).
    page = Activity.notifications_page(user.id, limit: @page_size)
    items = with_post_previews(page.entries, user)

    # The exact feed size backs the "Load N of M more" countdown, but a full
    # count across every source is the heaviest query on this page. Skip it on
    # the static first paint (where the label falls back to a plain "Load more")
    # and compute it only once the socket is connected, so the initial HTTP
    # render stays lean. Live-pushed events show up immediately, so they never
    # touch this number.
    remaining =
      if connected?(socket),
        do: max(Activity.notifications_count(user.id) - length(page.entries), 0),
        else: 0

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:empty?, Enum.empty?(page.entries))
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:remaining, remaining)
     # The shown items, kept so the midnight :day_changed tick can re-render each
     # quoted-post stamp in place (streams don't retain their data).
     |> assign(:items, items)
     |> stream(:notifications, items, dom_id: &"notification-#{&1.id}")}
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Activity.notifications_page(socket.assigns.current_user.id,
        limit: @page_size,
        cursor: socket.assigns.cursor
      )

    items = with_post_previews(page.entries, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> assign(:remaining, max(socket.assigns.remaining - length(page.entries), 0))
     |> update(:items, &(&1 ++ items))
     |> stream(:notifications, items, at: -1)}
  end

  @impl true
  def handle_info({:new_notification, notification}, socket) do
    [item] =
      notification
      |> Map.put_new(:kind, "activity")
      # Pushed events carry no row id, so mint one. The "live-" prefix keeps
      # them out of the derived "<kind>-<row id>" namespace - a pushed event
      # must prepend, never update a derived row in place.
      |> Map.put(:id, "live-#{System.unique_integer([:positive, :monotonic])}")
      # A pushed reply/like carries the post ids but no bodies; quote them like
      # the derived rows do.
      |> List.wrap()
      |> with_post_previews(socket.assigns.current_user)

    # The user is watching the event arrive, so it is already read: advance the
    # read marker, which broadcasts :notifications_read and keeps the shell's
    # bell badge at zero instead of bumping it for an event shown live here.
    Activity.mark_notifications_read(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:empty?, false)
     |> update(:items, &[item | &1])
     |> stream_insert(:notifications, item, at: 0)}
  end

  # The Berlin day rolled over at midnight (Vutuv.DayClock): re-render each shown
  # item so its quoted-post stamp moves "today" -> "Gestern". update_only
  # refreshes rows in place and skips any already gone (see PostLive.Feed).
  def handle_info(:day_changed, socket) do
    socket =
      Enum.reduce(socket.assigns.items, socket, fn item, socket ->
        stream_insert(socket, :notifications, item, update_only: true)
      end)

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notifications" class="py-8">
      <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Notifications")}</h1>

      <ul id="notification-list" phx-update="stream" class="mt-6 space-y-3">
        <li
          :for={{dom_id, n} <- @streams.notifications}
          id={dom_id}
          class="flex items-start gap-3 rounded-2xl bg-white px-4 py-3 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
        >
          <%!-- Show the actor's avatar (linked) when we have a picture; events
          whose payload carries no user struct (e.g. a bare-map broadcast) keep
          the colored kind glyph. Either way, a present actor (actor_id) gets the
          online-presence dot via <.presence_wrap> — picture-less actors render
          the glyph, so the dot must ride that too, not only the avatar. --%>
          <%= if n[:actor_avatar] do %>
            <.link href={~p"/#{n.actor_param}"} class="mt-0.5 shrink-0">
              <.presence_wrap id={n[:actor_id]} size="sm">
                <.avatar src={n[:actor_avatar]} size="sm" alt={"Avatar of #{n.actor_name}"} />
              </.presence_wrap>
            </.link>
          <% else %>
            <.presence_wrap id={n[:actor_id]} size="sm">
              <span class={[
                "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
                kind_classes(n.kind)
              ]}>
                {kind_glyph(n.kind)}
              </span>
            </.presence_wrap>
          <% end %>
          <div class="min-w-0 flex-1">
            <% target = notification_target(n, @current_user) %>
            <p class="text-slate-800 dark:text-slate-100">
              <%= if n[:actor_param] do %>
                <.link href={~p"/#{n.actor_param}"} class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white">
                  {n.actor_name}
                </.link>
              <% else %>
                <span :if={n[:actor_name]} class="font-semibold">{n.actor_name}</span>
              <% end %>
              <%!-- The event text leads to the thing it reports: the liked or
              replied-to post, the connections page for a request, the actor's
              profile otherwise. --%>
              <%= if target do %>
                <.link href={target} class="hover:text-brand-700 hover:underline">
                  {notification_text(n)}
                </.link>
              <% else %>
                {notification_text(n)}
              <% end %>
            </p>
            <%!-- For a like, quote the liked post; for a reply, quote both the
            recipient's own post that was replied to and the reply itself, each
            truncated to its first lines and linked to its own permalink, via the
            shared <.post_preview>. When both show, a caption tells them apart. --%>
            <% both_quotes? = n[:post_preview] && n[:reply_preview] %>
            <.post_preview
              :if={n[:post_preview]}
              post={n.post_preview.post}
              text={n.post_preview.text}
              truncated?={n.post_preview.truncated?}
              clamp="line-clamp-3 whitespace-pre-line"
              label={both_quotes? && gettext("Your post")}
              time_id={"notif-post-#{n.id}"}
              class="mt-2"
              data-post-preview="true"
            />
            <.post_preview
              :if={n[:reply_preview]}
              post={n.reply_preview.post}
              text={n.reply_preview.text}
              truncated?={n.reply_preview.truncated?}
              clamp="line-clamp-3 whitespace-pre-line"
              label={both_quotes? && gettext("Reply")}
              time_id={"notif-reply-#{n.id}"}
              class="mt-2"
              data-reply-preview="true"
            />
            <span class="text-xs uppercase tracking-wide text-slate-500">
              {kind_label(n.kind)}<span :if={n[:at]}> &middot; <.local_time id={"notif-at-#{n.id}"} at={n.at} format="%Y-%m-%d" /></span>
            </span>
          </div>
        </li>
      </ul>

      <p :if={@empty?} class="mt-6 text-slate-600 dark:text-slate-400">{gettext("Nothing new yet.")}</p>

      <.load_more :if={@more?} class="mt-6">{load_more_label(@remaining)}</.load_more>
    </div>
    """
  end

  # "Load 50 of 80 more": the next batch size, then everything still unloaded,
  # so the user can tell how far into the feed they are. Counts render in the
  # site-wide compact form (exact up to 999, then 1K/5M).
  #
  # `remaining` is a mount-time snapshot of the feed size, while more?/cursor
  # follow the live database, so the snapshot can run dry (<= 0) while older
  # pages still exist. Showing "Load 0 of 0 more" would be nonsense, so fall
  # back to a plain label once the snapshot can no longer count down.
  defp load_more_label(remaining) when remaining <= 0, do: gettext("Load more")

  defp load_more_label(remaining) do
    gettext("Load %{count} of %{remaining} more",
      count: compact_count(min(@page_size, remaining)),
      remaining: compact_count(remaining)
    )
  end

  # "connection" is the vernetzt (mutual-follow) event; it shares the follower
  # badge colour and gets the handshake glyph.
  @connection_kinds ~w(connection)

  # Event kinds that share the brand badge colour (follower/reply/connection/
  # the report-protection notice), so the class string lives in one place.
  @brand_kind_classes "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
  @brand_kinds ~w(follower reply connection report_protection)

  defp kind_classes("endorsement"),
    do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/30 dark:text-emerald-300"

  defp kind_classes("like"), do: "bg-accent/10 text-accent dark:bg-accent/20"

  defp kind_classes("moderation"),
    do: "bg-amber-50 text-amber-600 dark:bg-amber-900/30 dark:text-amber-200"

  defp kind_classes(kind) when kind in @brand_kinds, do: @brand_kind_classes

  defp kind_classes(_), do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-300"

  defp kind_glyph("follower"), do: "+"
  defp kind_glyph("endorsement"), do: "★"
  defp kind_glyph("reply"), do: "↩"
  defp kind_glyph("like"), do: "♥"
  defp kind_glyph(kind) when kind in @connection_kinds, do: "🤝"
  defp kind_glyph("moderation"), do: "⚑"
  defp kind_glyph("report_protection"), do: "🛡"
  defp kind_glyph(_), do: "•"

  # The small uppercase tag under the event text. Translated like the text
  # itself; raw kind strings ("connection_request") must not leak to users.
  defp kind_label("follower"), do: gettext("Follower")
  defp kind_label("endorsement"), do: gettext("Endorsement")
  defp kind_label("reply"), do: gettext("Reply")
  defp kind_label("like"), do: gettext("Like")
  defp kind_label("connection"), do: gettext("Connection")
  defp kind_label("moderation"), do: gettext("Moderation")
  defp kind_label("report_protection"), do: gettext("Report protection")
  defp kind_label(_), do: gettext("Activity")

  # Where clicking the event text leads. Events about one of the viewer's
  # posts open that post's thread; a pending request opens the page where it
  # can be answered; an endorsement the viewer's tags; everything else the
  # actor's profile. Logged-out renders (no viewer) only ever get the latter.
  # Moderation events lead to the owner's case page (and carry no actor).
  defp notification_target(%{kind: "moderation"} = n, viewer) do
    if is_binary(n[:case_id]) and viewer != nil, do: ~p"/moderation/cases/#{n.case_id}"
  end

  defp notification_target(n, viewer) do
    primary_target(n, viewer) || actor_target(n)
  end

  defp primary_target(%{kind: kind} = n, viewer) when kind in ["reply", "like"] do
    if is_binary(n[:post_id]) and viewer != nil, do: ~p"/#{viewer}/posts/#{n.post_id}"
  end

  defp primary_target(%{kind: "endorsement"}, viewer) when viewer != nil,
    do: ~p"/#{viewer}/tags"

  defp primary_target(_n, _viewer), do: nil

  defp actor_target(n) do
    if is_binary(n[:actor_param]), do: ~p"/#{n.actor_param}"
  end

  # The event text is rendered from the kind (not stored), so it translates
  # with the viewer's locale. Unknown kinds fall back to the pushed text.
  defp notification_text(%{kind: "follower"}), do: gettext("started following you.")

  defp notification_text(%{kind: "endorsement", tag: tag}),
    do: gettext("endorsed you for %{tag}.", tag: tag)

  defp notification_text(%{kind: "connection"}), do: gettext("is now connected with you.")

  defp notification_text(%{kind: "reply"}), do: gettext("replied to your post.")
  defp notification_text(%{kind: "like"}), do: gettext("liked your post.")

  # Moderation items carry no actor (reports are anonymous); the text alone
  # tells the owner what happened and links to the case page.
  defp notification_text(%{kind: "moderation"} = n) do
    case n[:status] do
      "upheld" -> gettext("A report about your content was confirmed.")
      "rejected" -> gettext("A report about your content was dismissed; it is visible again.")
      "resolved_edited" -> gettext("You revised reported content; the case is closed.")
      "resolved_deleted" -> gettext("You deleted reported content; the case is closed.")
      _ -> gettext("Your content was reported and is hidden while the report is handled.")
    end
  end

  # Reporter protection: the actor is the *reported* member, rendered as
  # @handle by the actor line; the text explains the both-ways pause and
  # that an unfounded ruling undoes it.
  defp notification_text(%{kind: "report_protection"} = n) do
    case n[:status] do
      "restored" ->
        gettext(
          "Our admins found your report unfounded; the paused connection between you two is restored."
        )

      _ ->
        gettext(
          "Your report paused the connection between you two - no contact in either direction for now. If our admins find the report unfounded, this is undone."
        )
    end
  end

  defp notification_text(n), do: n[:text]

  # Reply and like notifications carry post ids the row can quote: a like the
  # liked post (`:post_id`), a reply both the recipient's own post that was
  # replied to (`:post_id`) and the reply itself (`:reply_post_id`). Look every
  # referenced post up in one batched, visibility-scoped query and attach a
  # preview map `%{post:, text:, truncated?:}` as `:post_preview` /
  # `:reply_preview` — the shared `<.post_preview>` renders the author + permalink
  # from `post`, the first-lines plain-text excerpt from `text`. Other kinds carry
  # no ids, a photo-only post (empty body) yields no preview, and a reply hidden
  # from the viewer is absent from `posts`, so all pass through unchanged.
  defp with_post_previews(entries, viewer) do
    posts =
      entries
      |> Enum.flat_map(&[&1[:post_id], &1[:reply_post_id]])
      |> then(&Posts.visible_posts_by_ids(viewer, &1))

    Enum.map(entries, fn entry ->
      entry
      |> put_preview(:post_preview, entry[:post_id], posts)
      |> put_preview(:reply_preview, entry[:reply_post_id], posts)
    end)
  end

  defp put_preview(entry, key, post_id, posts) do
    with true <- is_binary(post_id),
         %Post{} = post <- Map.get(posts, post_id),
         %{} = excerpt <- preview_excerpt(post.body) do
      Map.put(entry, key, Map.put(excerpt, :post, post))
    else
      _ -> entry
    end
  end

  # How many source lines and characters the notification quote keeps.
  @preview_line_count 3
  @preview_char_limit 280

  # The plain-text excerpt shown under a reply/like notification: the post's
  # first three non-empty lines, capped so one very long line can't blow the
  # row up. Plain text (not rendered Markdown) to match the compact reply
  # context row on the profile. `truncated?` tells the row to append an ellipsis
  # when more was cut. Returns nil for a bodyless (photo-only) post. Kept
  # server-side (not a CSS clamp) so a hidden reply's body never reaches the DOM.
  defp preview_excerpt(body) do
    lines =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {shown, rest} = Enum.split(lines, @preview_line_count)
    text = Enum.join(shown, "\n")

    cond do
      text == "" -> nil
      String.length(text) > @preview_char_limit -> %{text: clamp(text), truncated?: true}
      true -> %{text: text, truncated?: rest != []}
    end
  end

  defp clamp(text), do: text |> String.slice(0, @preview_char_limit) |> String.trim_trailing()
end
