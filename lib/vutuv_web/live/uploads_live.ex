defmodule VutuvWeb.UploadsLive do
  @moduledoc """
  The member's own uploads queue at `/system/uploads` (issue #2106).

  A post carrying a clip or files is not published until the server is done
  with them, and that can be twenty minutes. The waiting card above the feed
  says so while the author is on the feed; this page is where they can go from
  anywhere — the app bar's chip links here — and it answers the two questions
  the card cannot: what exactly is still being worked on, and what happened to
  the ones from earlier.

  So it is two lists. **Waiting**, with the same stage sentence and the same
  two ways out the feed's card carries (`VutuvWeb.PendingPostComponents` and
  `VutuvWeb.Live.PendingPostActions`, so neither surface can word a stage or
  handle a press differently), and **history**, one line per finished row
  saying what it became — a link to the post, "dropped", or that it could not
  be published.
  """

  use VutuvWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import VutuvWeb.PendingPostComponents

  alias Vutuv.Posts
  alias Vutuv.Posts.Pending
  alias Vutuv.Posts.PendingPost
  alias Vutuv.Posts.Post
  alias Vutuv.Videos
  alias VutuvWeb.Live.PendingPostActions

  @events PendingPostActions.events()

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Pending.subscribe(user.id)

    {:ok, socket |> assign(:page_title, gettext("Your uploads")) |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @events do
    PendingPostActions.act(socket.assigns.current_user, event, params)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:pending_post, _summary}, socket), do: {:noreply, load(socket)}
  def handle_info({:attachment, _summary}, socket), do: {:noreply, load(socket)}

  # A clip's percent arrives every couple of points, so it is patched into the
  # row that holds it rather than re-reading the page — the feed's
  # `patch_waiting_video/2` for the same reason, and this page would otherwise
  # run its whole query set dozens of times per conversion.
  def handle_info({:post_video, summary}, socket) do
    if Enum.any?(socket.assigns.waiting, &stage_moved?(&1, summary)),
      do: {:noreply, load(socket)},
      else: {:noreply, update(socket, :waiting, &patch_percent(&1, summary))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp stage_moved?(%PendingPost{video: %{id: id} = video}, %{id: id} = summary),
    do: Videos.stage_changed?(video, summary)

  defp stage_moved?(%PendingPost{}, _summary), do: false

  defp patch_percent(rows, %{id: video_id} = summary) do
    Enum.map(rows, fn
      %PendingPost{video: %{id: ^video_id} = held} = row ->
        %{row | video: Videos.apply_summary(held, summary)}

      row ->
        row
    end)
  end

  defp load(socket) do
    user = socket.assigns.current_user
    history = Pending.history_for(user)
    {waiting, finished} = Enum.split_with(history, &(&1.status == "waiting"))

    socket
    |> assign(:waiting, waiting)
    |> assign(:readings, Pending.readings(waiting))
    |> assign(:history, finished)
    |> assign(:posts, published_posts(finished))
  end

  # The posts the finished rows became, in **one** query with only the two
  # associations `Vutuv.Posts.path/1` needs. `Posts.get_post/1` would force the
  # full post preload set per row, which on a page of fifty is a thousand
  # queries for a link.
  defp published_posts(rows) do
    ids = for %PendingPost{status: "published", post_id: id} <- rows, is_binary(id), do: id

    if ids == [] do
      %{}
    else
      from(p in Post, where: p.id in ^ids, preload: [:user, :organization])
      |> Vutuv.Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <.page_header title={gettext("Your uploads")} />

      <.card>
        <.section_title>{gettext("Waiting")}</.section_title>
        <p :if={@waiting == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Nothing is waiting. Every post you wrote is published.")}
        </p>
        <div id="waiting-posts">
          <.pending_post
            :for={pending <- @waiting}
            pending={pending}
            reading={@readings[pending.id]}
            body_html={body_html(pending)}
          />
        </div>
      </.card>

      <.card class="mt-6">
        <.section_title>{gettext("Earlier")}</.section_title>
        <p :if={@history == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Nothing here yet.")}
        </p>
        <ul id="upload-history" class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
          <li
            :for={row <- @history}
            class="flex flex-wrap items-baseline gap-x-3 gap-y-1 py-2 text-sm"
            data-upload-row={row.id}
            data-upload-status={row.status}
          >
            <.local_time
              at={row.inserted_at}
              id={"upload-#{row.id}-time"}
              style={:datetime}
              class="shrink-0 text-xs text-slate-500 dark:text-slate-400"
            />
            <span class="min-w-0 flex-1 truncate text-slate-700 dark:text-slate-200">
              {excerpt(row)}
            </span>
            <.link
              :if={@posts[row.post_id]}
              navigate={Posts.path(@posts[row.post_id])}
              class="shrink-0 font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Published")}
            </.link>
            <span :if={!@posts[row.post_id]} class="shrink-0 text-slate-500 dark:text-slate-400">
              {status_label(row.status)}
            </span>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  # What became of a row whose post is not there to link to. The failure reason
  # is deliberately not shown: it is `inspect/1` of an internal term and means
  # nothing to the author.
  defp status_label("canceled"), do: gettext("Dropped")
  defp status_label("failed"), do: gettext("Could not be published")
  defp status_label("publishing"), do: gettext("Being published")
  defp status_label(_published_but_deleted), do: gettext("Deleted")

  # One line of the text, so a member recognises which post a row is about.
  # Cut before rendering, the way `VutuvWeb.PostTeaser.opening/2` does: a 10k
  # body flattened whole to keep 140 characters is work nobody sees.
  defp excerpt(%PendingPost{} = pending) do
    case Pending.body(pending) do
      nil ->
        gettext("(no text)")

      body ->
        body
        |> String.slice(0, 560)
        |> VutuvWeb.Markdown.to_plain_text()
        |> String.slice(0, 140)
    end
  end

  defp body_html(%PendingPost{} = pending) do
    case Pending.body(pending) do
      nil -> nil
      body -> VutuvWeb.Markdown.render_post(body, [])
    end
  end
end
