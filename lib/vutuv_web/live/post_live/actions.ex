defmodule VutuvWeb.PostLive.Actions do
  @moduledoc """
  The per-card action bar: like / repost / bookmark buttons with live
  counters.

  One small LiveView per rendered post card, embedded via `live_render`
  from `VutuvWeb.PostComponents.post_card/1` — on the LiveView feed *and*
  on the dead pages (permalink, profile, archive), so the counters update
  in real time everywhere a post is on screen. It subscribes to the post's
  topic and re-renders on `{:post_counters, …}` (absolute counts, so
  updates are idempotent).

  Logged-out viewers get the same live counters; pressing a button sends
  them to the login page. Restricted posts render a disabled repost button
  (only public posts can be reposted — `Vutuv.Posts.repost_post/2`).

  Mounted outside the `live_session` (embedded), so it applies the session
  locale itself, like `VutuvWeb.ShellLive`.
  """
  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI, only: [compact_count: 1]

  alias Vutuv.Posts

  @impl true
  def mount(_params, session, socket) do
    post_id = session["post_id"]
    viewer_id = session["user_id"]
    VutuvWeb.LiveLocale.put_locale(session)

    if connected?(socket) do
      Posts.subscribe_post(post_id)
      # The viewer's own activity topic: an {:engagement_changed, …} from
      # another of their sessions re-syncs the liked/bookmarked/reposted
      # flags here (the post topic only carries counts).
      Vutuv.Activity.subscribe(viewer_id)
    end

    {:ok,
     socket
     |> assign(:id, session["id"])
     |> assign(:post_id, post_id)
     |> assign(:viewer_id, viewer_id)
     |> load_engagement()}
  end

  # The post can vanish between page render and socket mount (or while the
  # page is open) — engagement turns nil and the bar simply empties.
  defp load_engagement(socket) do
    assign(
      socket,
      :engagement,
      Posts.post_engagement(socket.assigns.post_id, socket.assigns.viewer_id)
    )
  end

  @impl true
  def handle_event("toggle", %{"kind" => kind}, socket) when kind in ~w(like bookmark repost) do
    case {socket.assigns.viewer_id, socket.assigns.engagement} do
      {nil, _} ->
        {:noreply, redirect(socket, to: ~p"/login")}

      {_, nil} ->
        {:noreply, socket}

      {viewer_id, engagement} ->
        toggle(kind, viewer_id, engagement, socket)
    end
  end

  defp toggle(kind, viewer_id, engagement, socket) do
    user = Vutuv.Repo.get(Vutuv.Accounts.User, viewer_id)
    post = Vutuv.Repo.get(Vutuv.Posts.Post, socket.assigns.post_id)

    if user && post do
      # Errors (:not_visible, :restricted) mean the button should not have
      # been live — the reload below shows the truth either way.
      _ =
        case {kind, engagement} do
          {"like", %{liked?: true}} -> Posts.unlike_post(user, post)
          {"like", _} -> Posts.like_post(user, post)
          {"bookmark", %{bookmarked?: true}} -> Posts.unbookmark_post(user, post)
          {"bookmark", _} -> Posts.bookmark_post(user, post)
          {"repost", %{reposted?: true}} -> Posts.unrepost_post(user, post)
          {"repost", _} -> Posts.repost_post(user, post)
        end
    end

    # The broadcast updates the counters everywhere; the viewer's own flags
    # are not in it, so reload both here.
    {:noreply, load_engagement(socket)}
  end

  @impl true
  def handle_info(
        {:post_counters, %{likes: likes, bookmarks: bookmarks, reposts: reposts}},
        socket
      ) do
    case socket.assigns.engagement do
      nil ->
        {:noreply, socket}

      engagement ->
        {:noreply,
         assign(socket, :engagement, %{
           engagement
           | likes: likes,
             bookmarks: bookmarks,
             reposts: reposts
         })}
    end
  end

  # The viewer toggled this post in another tab: reload, so their own flag
  # state (filled heart etc.) stays in sync everywhere, not just the counts.
  def handle_info({:engagement_changed, %{post_id: post_id}}, socket) do
    if post_id == socket.assigns.post_id do
      {:noreply, load_engagement(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@engagement} class="-ml-2 mt-3 flex items-center gap-1 text-slate-500 dark:text-slate-400">
      <.action_button
        id={"#{@id}-like"}
        kind="like"
        active?={@engagement.liked?}
        count={@engagement.likes}
        label={if @engagement.liked?, do: gettext("Unlike"), else: gettext("Like")}
        active_class="text-accent"
      >
        <:icon><.icon_heart filled?={@engagement.liked?} /></:icon>
      </.action_button>

      <.action_button
        id={"#{@id}-repost"}
        kind="repost"
        active?={@engagement.reposted?}
        count={@engagement.reposts}
        label={if @engagement.reposted?, do: gettext("Undo repost"), else: gettext("Repost")}
        active_class="text-brand-600 dark:text-brand-300"
        disabled={@engagement.restricted?}
        disabled_title={gettext("Only public posts can be reposted.")}
      >
        <:icon><.icon_repost /></:icon>
      </.action_button>

      <.action_button
        id={"#{@id}-bookmark"}
        kind="bookmark"
        active?={@engagement.bookmarked?}
        count={@engagement.bookmarks}
        label={if @engagement.bookmarked?, do: gettext("Remove bookmark"), else: gettext("Bookmark")}
        active_class="text-brand-600 dark:text-brand-300"
      >
        <:icon><.icon_bookmark filled?={@engagement.bookmarked?} /></:icon>
      </.action_button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:count, :integer, required: true)
  attr(:label, :string, required: true)
  attr(:active_class, :string, required: true)
  attr(:disabled, :boolean, default: false)
  attr(:disabled_title, :string, default: nil)
  slot(:icon, required: true)

  defp action_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="toggle"
      phx-value-kind={@kind}
      disabled={@disabled}
      aria-pressed={to_string(@active?)}
      aria-label={@label}
      title={if(@disabled, do: @disabled_title, else: @label)}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm",
        @disabled && "cursor-not-allowed opacity-40",
        !@disabled && "hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors bare `a, button` brand-600, which beats the
        # wrapper's inherited slate — so the state color sits on the button.
        if(@active?, do: @active_class, else: "text-slate-500 dark:text-slate-400")
      ]}
    >
      {render_slot(@icon)}
      <%!-- Always mounted (invisible at zero) so an arriving first count
            doesn't shift the neighbouring buttons under the pointer. --%>
      <span
        class={["font-medium tabular-nums", @count == 0 && "invisible"]}
        data-count={@count > 0 && @kind}
      >
        {compact_count(@count)}
      </span>
    </button>
    """
  end

  attr(:filled?, :boolean, default: false)

  defp icon_heart(assigns) do
    ~H"""
    <svg
      class="h-5 w-5"
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z"
      />
    </svg>
    """
  end

  defp icon_repost(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 12c0-1.232-.046-2.453-.138-3.662a4.006 4.006 0 0 0-3.7-3.7 48.678 48.678 0 0 0-7.324 0 4.006 4.006 0 0 0-3.7 3.7c-.017.22-.032.441-.046.662M19.5 12l3-3m-3 3-3-3m-12 3c0 1.232.046 2.453.138 3.662a4.006 4.006 0 0 0 3.7 3.7 48.656 48.656 0 0 0 7.324 0 4.006 4.006 0 0 0 3.7-3.7c.017-.22.032-.441.046-.662M4.5 12l3 3m-3-3-3 3"
      />
    </svg>
    """
  end

  attr(:filled?, :boolean, default: false)

  defp icon_bookmark(assigns) do
    ~H"""
    <svg
      class="h-5 w-5"
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M17.593 3.322c.1.128.157.288.157.456v16.444a.75.75 0 0 1-1.218.585L12 17.21l-4.532 3.597A.75.75 0 0 1 6.25 20.222V3.778c0-.168.057-.328.157-.456A2.25 2.25 0 0 1 8.25 2.5h7.5a2.25 2.25 0 0 1 1.843.822Z"
      />
    </svg>
    """
  end
end
