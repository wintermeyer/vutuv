defmodule VutuvWeb.PostLive.Saved do
  @moduledoc """
  The private saved-items hub: `/likes` and `/bookmarks`. Two top-level tabs
  (the live actions `:likes` / `:bookmarks`), each with a **Posts / People**
  sub-tab (`?tab=people`), a **search** box (`?q=`) and a **sort** control
  (`?sort=recent|oldest|name`). All three ride in the URL via `push_patch`, so a
  filtered list stays shareable and reloadable.

  Saved **posts** and saved **people** are both shown (issue #792): a member can
  like / bookmark another member from any profile, no follow or connection
  required, and they surface here beside the saved posts.

  Un-saving removes the row live: a post drops on `{:engagement_changed, …}`
  (every shown card subscribes to its own post topic; a liker/bookmarker rarely
  follows the author, so the feed broadcast does not reach them), and a person
  drops on the People tab's own Remove control or on `{:user_engagement_changed,
  …}` from another session — both on the actor's activity topic.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents
  import VutuvWeb.PostComponents
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Jobs
  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias VutuvWeb.Live.DayClockRestream

  @page_size 20

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Vutuv.Activity.subscribe(socket.assigns.current_user.id)
      # Roll the shown posts' Berlin-day stamps over at midnight without a reload.
      Vutuv.DayClock.subscribe()
    end

    {:ok,
     socket
     |> assign(:post_engagement, %{})
     # The posts currently on screen (empty on the People tab), kept so the
     # midnight :day_changed tick can re-render each stamp in place.
     |> assign(:saved_posts, [])
     |> stream(:posts, [])
     |> stream(:people, [])
     |> stream(:organizations, [])
     |> stream(:jobs, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:type, parse_type(params["tab"]))
      |> assign(:q, params["q"] || "")
      |> assign(:sort, parse_sort(params["sort"]))

    {stream_name, page} = load_page(socket, 0)
    if connected?(socket) and stream_name == :posts, do: subscribe_posts(page.entries)

    {:noreply,
     socket
     |> assign(:page_title, title(socket.assigns.live_action))
     |> assign(:more?, page.more?)
     |> assign(:offset, page.next_offset)
     |> assign(:saved_posts, if(stream_name == :posts, do: page.entries, else: []))
     |> assign(
       :post_engagement,
       page_engagement(stream_name, page.entries, socket.assigns.current_user)
     )
     |> stream(stream_name, page.entries, reset: true)}
  end

  # Batch the action-bar engagement for a whole posts page in one query, keyed by
  # post id, so the per-card Actions LiveViews skip their own mount query (this
  # tab used to fire one query per card). The People tab has no posts.
  defp page_engagement(:posts, entries, user),
    do: Posts.post_engagement_map(Enum.map(entries, & &1.id), user)

  defp page_engagement(_type, _entries, _user), do: %{}

  defp load_page(socket, offset) do
    user = socket.assigns.current_user

    opts = [
      limit: @page_size,
      offset: offset,
      search: socket.assigns.q,
      sort: socket.assigns.sort
    ]

    case {socket.assigns.live_action, socket.assigns.type} do
      {:likes, :posts} ->
        {:posts, Posts.liked_posts_page(user, opts)}

      {:bookmarks, :posts} ->
        {:posts, Posts.bookmarked_posts_page(user, opts)}

      {:likes, :people} ->
        {:people, Social.liked_users_page(user, opts)}

      {:bookmarks, :people} ->
        {:people, Social.bookmarked_users_page(user, opts)}

      {:likes, :organizations} ->
        {:organizations, Organizations.saved_organizations_page(user, :like, opts)}

      {:bookmarks, :organizations} ->
        {:organizations, Organizations.saved_organizations_page(user, :bookmark, opts)}

      {:likes, :jobs} ->
        {:jobs, Jobs.saved_job_postings_page(user, :like, opts)}

      {:bookmarks, :jobs} ->
        {:jobs, Jobs.saved_job_postings_page(user, :bookmark, opts)}
    end
  end

  defp subscribe_posts(entries), do: Enum.each(entries, &Posts.subscribe_post(&1.id))

  defp parse_type("people"), do: :people
  defp parse_type("organizations"), do: :organizations
  defp parse_type("jobs"), do: :jobs
  defp parse_type(_), do: :posts

  defp parse_sort("oldest"), do: :oldest
  defp parse_sort("name"), do: :name
  defp parse_sort(_), do: :recent

  defp title(:likes), do: gettext("Likes")
  defp title(:bookmarks), do: gettext("Bookmarks")

  defp tab_kind(:likes), do: :like
  defp tab_kind(:bookmarks), do: :bookmark

  # ── Events ──

  @impl true
  def handle_event("load-more", _params, socket) do
    {stream_name, page} = load_page(socket, socket.assigns.offset)
    if stream_name == :posts, do: subscribe_posts(page.entries)
    user = socket.assigns.current_user

    socket =
      if stream_name == :posts,
        do: update(socket, :saved_posts, &(&1 ++ page.entries)),
        else: socket

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:offset, page.next_offset)
     |> update(:post_engagement, &Map.merge(&1, page_engagement(stream_name, page.entries, user)))
     |> stream(stream_name, page.entries, at: -1)}
  end

  # The search box and the sort select share one form; either change patches the
  # URL (so the filter is shareable and handle_params does the actual reload).
  def handle_event("filter", params, socket) do
    to =
      saved_path(
        socket.assigns.live_action,
        socket.assigns.type,
        params["q"] || "",
        params["sort"]
      )

    {:noreply, push_patch(socket, to: to)}
  end

  # The People tab's inline Remove: un-save right here and drop the row. The
  # context scopes the delete to (me, target). A non-UUID id is a genuine no-op
  # (cast_or_nil) — building %User{id: id} from the raw phx-value used to raise
  # an Ecto.CastError in the scoped delete despite the "harmless" comment.
  def handle_event("unsave-person", %{"id" => id}, socket) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil ->
        {:noreply, socket}

      uuid ->
        target = %User{id: uuid}

        case socket.assigns.live_action do
          :likes -> Social.unlike_user(socket.assigns.current_user, target)
          :bookmarks -> Social.unbookmark_user(socket.assigns.current_user, target)
        end

        {:noreply, stream_delete_by_dom_id(socket, :people, "people-#{uuid}")}
    end
  end

  def handle_event("remove_organization", %{"id" => id}, socket) do
    # Cast first (like unsave-person above): a tampered non-UUID id would raise
    # Ecto.Query.CastError in the binary_id lookup and crash the LiveView.
    with uuid when not is_nil(uuid) <- Vutuv.UUIDv7.cast_or_nil(id),
         %Organizations.Organization{} = organization <- Organizations.get_organization(uuid) do
      case socket.assigns.live_action do
        :likes ->
          Organizations.unlike_organization(socket.assigns.current_user, organization)

        :bookmarks ->
          Organizations.unbookmark_organization(socket.assigns.current_user, organization)
      end

      {:noreply,
       stream_delete_by_dom_id(socket, :organizations, "organizations-#{organization.id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_job", %{"id" => id}, socket) do
    with uuid when not is_nil(uuid) <- Vutuv.UUIDv7.cast_or_nil(id),
         %Jobs.JobPosting{} = posting <- Jobs.get_job_posting(uuid) do
      case socket.assigns.live_action do
        :likes -> Jobs.unlike_job_posting(socket.assigns.current_user, posting)
        :bookmarks -> Jobs.unbookmark_job_posting(socket.assigns.current_user, posting)
      end

      {:noreply, stream_delete_by_dom_id(socket, :jobs, "jobs-#{posting.id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Live sync ──

  @impl true
  def handle_info(
        {:engagement_changed, %{kind: kind, post_id: post_id, active?: active?}},
        socket
      ) do
    if socket.assigns.type == :posts and kind == tab_kind(socket.assigns.live_action) do
      {:noreply, apply_post_change(socket, post_id, active?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:user_engagement_changed, %{kind: kind, target_user_id: target_id, active?: active?}},
        socket
      ) do
    if socket.assigns.type == :people and kind == tab_kind(socket.assigns.live_action) do
      {:noreply, apply_person_change(socket, target_id, active?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:organization_engagement_changed,
         %{kind: kind, organization_id: organization_id, active?: active?}},
        socket
      ) do
    if socket.assigns.type == :organizations and kind == tab_kind(socket.assigns.live_action) do
      {:noreply, apply_organization_change(socket, organization_id, active?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:job_posting_engagement_changed,
         %{kind: kind, job_posting_id: job_posting_id, active?: active?}},
        socket
      ) do
    if socket.assigns.type == :jobs and kind == tab_kind(socket.assigns.live_action) do
      {:noreply, apply_job_change(socket, job_posting_id, active?)}
    else
      {:noreply, socket}
    end
  end

  # A shown post was deleted (by its author or via account teardown): drop the
  # card instead of leaving a ghost whose action bar has emptied itself.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :posts, "posts-#{post_id}")}
  end

  # The Berlin day rolled over at midnight (Vutuv.DayClock): re-render each shown
  # post's stamp ("today" -> "Gestern"). No-op on the People tab (@saved_posts is
  # empty there). Shared with the feed + notifications; see
  # VutuvWeb.Live.DayClockRestream.
  def handle_info(:day_changed, socket) do
    {:noreply, DayClockRestream.restream(socket, :saved_posts, :posts)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp apply_post_change(socket, post_id, false) do
    stream_delete_by_dom_id(socket, :posts, "posts-#{post_id}")
  end

  defp apply_post_change(socket, post_id, true) do
    # Only prepend on the default, unfiltered recent view (like the person / org
    # / job handlers); under a search or non-recency sort a fresh save's position
    # is ambiguous, so leave it for the next reload.
    if default_view?(socket) do
      case Posts.get_post(post_id) do
        nil ->
          socket

        post ->
          Posts.subscribe_post(post.id)

          # Hand the inserted card its engagement, like the initial page does, so
          # the action-bar component renders straight from it instead of querying
          # during this broadcast-triggered render.
          socket
          |> update(
            :post_engagement,
            &Map.put(&1, post.id, Posts.post_engagement(post.id, socket.assigns.current_user.id))
          )
          |> update(:saved_posts, &[post | &1])
          |> stream_insert(:posts, post, at: 0)
      end
    else
      socket
    end
  end

  defp apply_person_change(socket, target_id, false) do
    stream_delete_by_dom_id(socket, :people, "people-#{target_id}")
  end

  defp apply_person_change(socket, target_id, true) do
    # Only prepend on the default, unfiltered recent view, where a fresh save
    # belongs at the top; under a search or a non-recency sort the right
    # position is ambiguous, so leave it for the next reload.
    if default_view?(socket) do
      case Repo.get(User, target_id) do
        %User{} = user -> stream_insert(socket, :people, user, at: 0)
        nil -> socket
      end
    else
      socket
    end
  end

  defp apply_organization_change(socket, organization_id, false) do
    stream_delete_by_dom_id(socket, :organizations, "organizations-#{organization_id}")
  end

  defp apply_organization_change(socket, organization_id, true) do
    if default_view?(socket) do
      case Organizations.get_active_organization(organization_id) do
        %Organizations.Organization{} = organization ->
          stream_insert(socket, :organizations, organization, at: 0)

        nil ->
          socket
      end
    else
      socket
    end
  end

  defp apply_job_change(socket, job_posting_id, false) do
    stream_delete_by_dom_id(socket, :jobs, "jobs-#{job_posting_id}")
  end

  defp apply_job_change(socket, job_posting_id, true) do
    if default_view?(socket) do
      case Jobs.get_job_posting(job_posting_id) do
        %Jobs.JobPosting{frozen_at: nil} = posting ->
          stream_insert(socket, :jobs, Vutuv.Repo.preload(posting, :organization), at: 0)

        _ ->
          socket
      end
    else
      socket
    end
  end

  # A fresh save prepends into the stream only on the default, unfiltered recent
  # view; under a search or a non-recency sort its position is ambiguous, so we
  # leave it for the next reload.
  defp default_view?(socket) do
    socket.assigns.q == "" and socket.assigns.sort == :recent
  end

  # ── Path / labels ──

  # The current page's URL with the non-default filters as query params, so tab
  # links and the filter form keep search + sort in sync.
  defp saved_path(action, type, q, sort) do
    query =
      []
      |> put_param(:tab, type_param(type))
      |> put_param(:q, q != "" && q)
      |> put_param(:sort, sort not in [nil, "", "recent"] && to_string(sort))

    case action do
      :likes -> ~p"/likes?#{query}"
      :bookmarks -> ~p"/bookmarks?#{query}"
    end
  end

  defp put_param(list, _key, false), do: list
  defp put_param(list, _key, nil), do: list
  defp put_param(list, key, value), do: list ++ [{key, value}]

  defp type_param(:people), do: "people"
  defp type_param(:organizations), do: "organizations"
  defp type_param(:jobs), do: "jobs"
  defp type_param(_posts), do: false

  defp sort_options do
    [
      {gettext("Newest first"), "recent"},
      {gettext("Oldest first"), "oldest"},
      {gettext("Name (A-Z)"), "name"}
    ]
  end

  # ── Render ──

  @impl true
  def render(assigns) do
    ~H"""
    <div id="saved" class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {title(@live_action)}
        </h1>

        <nav class="flex gap-1 text-sm font-semibold" aria-label={gettext("Saved items")}>
          <.tab patch={saved_path(:likes, @type, @q, @sort)} active?={@live_action == :likes} id="tab-likes">
            {gettext("Likes")}
          </.tab>
          <.tab patch={saved_path(:bookmarks, @type, @q, @sort)} active?={@live_action == :bookmarks} id="tab-bookmarks">
            {gettext("Bookmarks")}
          </.tab>
        </nav>

        <%!-- Posts / People sub-tabs: each keeps the active search + sort. --%>
        <nav class="flex gap-4 border-b border-slate-200 text-sm font-semibold dark:border-slate-800" aria-label={gettext("Saved type")}>
          <.subtab patch={saved_path(@live_action, :posts, @q, @sort)} active?={@type == :posts} id="subtab-posts">
            {gettext("Posts")}
          </.subtab>
          <.subtab patch={saved_path(@live_action, :people, @q, @sort)} active?={@type == :people} id="subtab-people">
            {gettext("People")}
          </.subtab>
          <.subtab patch={saved_path(@live_action, :organizations, @q, @sort)} active?={@type == :organizations} id="subtab-organizations">
            {gettext("Organizations")}
          </.subtab>
          <.subtab patch={saved_path(@live_action, :jobs, @q, @sort)} active?={@type == :jobs} id="subtab-jobs">
            {gettext("Jobs")}
          </.subtab>
        </nav>

        <.form for={%{}} id="saved-filter" phx-change="filter" class="flex flex-col gap-2 sm:flex-row sm:items-center">
          <input
            type="search"
            name="q"
            value={@q}
            phx-debounce="300"
            placeholder={gettext("Search saved items")}
            aria-label={gettext("Search saved items")}
            class={[input_class(), "sm:flex-1"]}
          />
          <select name="sort" aria-label={gettext("Sort")} class={[input_class(), "sm:w-auto"]}>
            <option :for={{label, value} <- sort_options()} value={value} selected={to_string(@sort) == value}>
              {label}
            </option>
          </select>
        </.form>

        <%= cond do %>
          <% @type == :posts -> %>
            <%!-- One card of flat divide-y rows via the shared
            <.post_thread_entry> — the same treatment as the feed and the profile,
            so a reply nests the post it answers. The empty <p> uses the only:block
            trick (like the People tab below) so un-saving the last post reveals it
            with no emptiness bookkeeping. --%>
            <.post_list id="saved-posts" phx-update="stream" data-post-list>
              <p class="hidden py-4 text-slate-600 dark:text-slate-400 only:block" id="saved-posts-empty">
                {posts_empty_text(@live_action, @q)}
              </p>
              <div :for={{dom_id, post} <- @streams.posts} id={dom_id} class={post_row_class()}>
                <.post_thread_entry
                  post={post}
                  viewer={@current_user}
                  conn_or_socket={@socket}
                  engagement={Map.get(@post_engagement, post.id)}
                  surface={:flat}
                />
              </div>
            </.post_list>
          <% @type == :people -> %>
            <ul id="saved-people" phx-update="stream" class="divide-y divide-slate-100 dark:divide-slate-800">
              <li class="hidden py-4 text-slate-600 dark:text-slate-400 only:block" id="saved-people-empty">
                {people_empty_text(@live_action, @q)}
              </li>
              <.person_row
                :for={{dom_id, person} <- @streams.people}
                id={dom_id}
                person={person}
                kind={@live_action}
                needle={@q}
              />
            </ul>
          <% @type == :organizations -> %>
            <ul id="saved-organizations" phx-update="stream" class="divide-y divide-slate-100 dark:divide-slate-800">
              <li class="hidden py-4 text-slate-600 dark:text-slate-400 only:block" id="saved-organizations-empty">
                {organizations_empty_text(@live_action, @q)}
              </li>
              <li
                :for={{dom_id, organization} <- @streams.organizations}
                id={dom_id}
                class="flex items-center gap-3 py-3"
              >
                <.link navigate={~p"/organizations/#{organization.slug}"} class="flex min-w-0 flex-1 items-center gap-3">
                  <.organization_logo organization={organization} class="h-10 w-10 shrink-0" />
                  <span class="min-w-0">
                    <span class="block truncate font-semibold text-slate-900 dark:text-slate-100">
                      {organization.name}
                    </span>
                    <.organization_location organization={organization} class="block truncate text-sm text-slate-600 dark:text-slate-400" />
                  </span>
                </.link>
                <button
                  type="button"
                  phx-click="remove_organization"
                  phx-value-id={organization.id}
                  class="shrink-0 text-sm font-semibold text-slate-500 hover:text-red-600 dark:text-slate-400"
                >
                  {gettext("Remove")}
                </button>
              </li>
            </ul>
          <% true -> %>
            <ul id="saved-jobs" phx-update="stream" class="divide-y divide-slate-100 dark:divide-slate-800">
              <li class="hidden py-4 text-slate-600 dark:text-slate-400 only:block" id="saved-jobs-empty">
                {jobs_empty_text(@live_action, @q)}
              </li>
              <li
                :for={{dom_id, posting} <- @streams.jobs}
                id={dom_id}
                class="flex items-center gap-3 py-3"
              >
                <.link navigate={~p"/jobs/#{posting.slug}"} class="min-w-0 flex-1">
                  <span class="block truncate font-semibold text-slate-900 dark:text-slate-100">
                    {posting.title}
                  </span>
                  <span :if={posting.organization} class="block truncate text-sm text-slate-600 dark:text-slate-400">
                    {posting.organization.name}
                  </span>
                </.link>
                <button
                  type="button"
                  phx-click="remove_job"
                  phx-value-id={posting.id}
                  class="shrink-0 text-sm font-semibold text-slate-500 hover:text-red-600 dark:text-slate-400"
                >
                  {gettext("Remove")}
                </button>
              </li>
            </ul>
        <% end %>

        <.load_more :if={@more?} />
      </div>
    </div>
    """
  end

  defp posts_empty_text(:likes, ""), do: gettext("Nothing here yet. Posts you like show up here.")

  defp posts_empty_text(:bookmarks, ""),
    do: gettext("Nothing here yet. Posts you bookmark show up here.")

  defp posts_empty_text(_action, _q), do: gettext("No saved posts match your search.")

  defp people_empty_text(:likes, ""),
    do: gettext("Nothing here yet. People you like show up here.")

  defp people_empty_text(:bookmarks, ""),
    do: gettext("Nothing here yet. People you bookmark show up here.")

  defp people_empty_text(_action, _q), do: gettext("No saved people match your search.")

  defp organizations_empty_text(:likes, ""),
    do: gettext("Nothing here yet. Organizations you like show up here.")

  defp organizations_empty_text(:bookmarks, ""),
    do: gettext("Nothing here yet. Organizations you bookmark show up here.")

  defp organizations_empty_text(_action, _q),
    do: gettext("No saved organizations match your search.")

  defp jobs_empty_text(:likes, ""), do: gettext("Nothing here yet. Jobs you like show up here.")

  defp jobs_empty_text(:bookmarks, ""),
    do: gettext("Nothing here yet. Jobs you bookmark show up here.")

  defp jobs_empty_text(_action, _q), do: gettext("No saved jobs match your search.")

  attr(:patch, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:id, :string, required: true)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      id={@id}
      aria-current={@active? && "page"}
      class={[
        "rounded-lg px-3 py-1.5",
        @active? && "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
        !@active? &&
          "text-slate-500 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-800"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr(:patch, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:id, :string, required: true)
  slot(:inner_block, required: true)

  defp subtab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      id={@id}
      aria-current={@active? && "page"}
      class={[
        "-mb-px border-b-2 px-1 py-2",
        @active? && "border-brand-600 text-brand-700 dark:border-brand-400 dark:text-brand-200",
        !@active? &&
          "border-transparent text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # A saved member: avatar, name + @handle, headline, and the inline Remove
  # toggle (filled bookmark / heart, matching the active tab) that un-saves and
  # drops the row live.
  attr(:id, :string, required: true)
  attr(:person, User, required: true)
  attr(:kind, :atom, required: true)
  attr(:needle, :string, default: "")

  defp person_row(assigns) do
    ~H"""
    <li id={@id} class="flex items-center gap-3 py-4">
      <.link navigate={~p"/#{@person}"} class="shrink-0">
        <.avatar user={@person} size="sm" alt={"Avatar of #{full_name(@person)}"} presence />
      </.link>
      <div class="min-w-0 flex-1 text-sm">
        <.link navigate={~p"/#{@person}"} class="block truncate font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100">
          {highlight(full_name(@person), @needle)}
          <span class="font-normal text-slate-600 dark:text-slate-400">@{@person.username}</span>
        </.link>
        <p :if={present_headline(@person)} class="mb-0 truncate text-sm text-slate-600 dark:text-slate-400">
          {highlight(present_headline(@person), @needle)}
        </p>
      </div>
      <button
        type="button"
        phx-click="unsave-person"
        phx-value-id={@person.id}
        title={remove_label(@kind)}
        aria-label={remove_label(@kind)}
        class="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-brand-600 ring-1 ring-inset ring-brand-200 transition hover:bg-brand-50 dark:text-brand-300 dark:ring-brand-900/50 dark:hover:bg-brand-900/30"
      >
        <.icon_heart :if={@kind == :likes} filled?={true} class="h-5 w-5" />
        <.icon_bookmark :if={@kind == :bookmarks} filled?={true} class="h-5 w-5" />
      </button>
    </li>
    """
  end

  defp remove_label(:likes), do: gettext("Unlike")
  defp remove_label(:bookmarks), do: gettext("Remove bookmark")

  # Headlines are short Markdown; on this compact row show the plain text only.
  defp present_headline(%User{headline: headline}) when is_binary(headline) do
    case String.trim(headline) do
      "" -> nil
      text -> text
    end
  end

  defp present_headline(_), do: nil
end
