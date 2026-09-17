defmodule VutuvWeb.PostLive.TagSources do
  @moduledoc """
  "Where should #tag come from?" — the chip on a followed tag, and the panel it
  opens (issue #2128).

  A followed tag has carried its sources since #2125 and has been pulling from
  them since #2126, with nothing anywhere saying so. This is the first thing a
  member can see and change about them: a number saying how many servers feed
  the tag, and a list of servers with their size beside them.

  ## One panel, two hosts

  The chip stands on every tag in the feed's tag card and beside the follow
  button on a tag page (`VutuvWeb.TagLive.Sources`, issue #2157), because the
  feed's rail is `hidden md:block` and a phone has no tag card. So this module is
  a LiveComponent that owns everything behind the chip — which tag is open, its
  rows, the last refusal, the switches, the typed field and the refresh — and a
  host renders it once, beside chips it draws itself:

      <.live_component module={TagSources} id="tag-sources" user={@user} tags={@tags} />
      <TagSources.source_chip tag={tag} count={count} open?={@open_id == tag.id} />

  `tags` is what the host offers a panel for; a tag that leaves it closes the
  panel. The chip is the host's markup, so the component says what the host has
  to redraw by message:

    * `{TagSources, {:panel, tag_id | nil}}` — which chip is `aria-expanded`;
    * `{TagSources, {:sources_changed, tag_id}}` — that chip's count is stale.

  ## Why it is a panel and not a dialog

  This app has no dialogs. The disclosure is how everything else here opens, and
  a panel that appears where the chip was pressed keeps the tag it is about on
  screen.

  ## What the markup owes the reader

  **The chip counts this installation too.** `1` is the honest answer for a tag
  nobody has added a server to; a chip that started at `0` would say the tag has
  no source at all.

  **vutuv's switch is `disabled`, not absent.** The reader has to be able to see
  that this installation *is* a source and that it is the one they cannot take
  away. The rule itself lives in the context, from both sides —
  `Vutuv.Tags.tag_follow_sources/1` answers with the local source whatever the
  rows say, and `remove_tag_follow_source/2` refuses to remove it — so the
  attribute here is a courtesy and never the permission.

  **Every answer stands where the member is looking** (issue #2166). A server
  typed into the field is listed directly above that field, not sorted in among
  the offers a long scroll further up, and the line saying it was taken sits
  under the field in a live region that is always rendered. At the cap, the
  sentence saying so stands above the switches it explains, and every switch it
  greys out points at it with `aria-describedby`.

  Everything else it draws is a row from `Vutuv.Tags.SourceServers.rows/1`.
  """

  use VutuvWeb, :live_component

  import VutuvWeb.PostComponents, only: [rail_field_class: 0]

  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServer
  alias Vutuv.Tags.SourceServers

  require Logger

  @impl true
  def mount(socket) do
    # Closed on arrival — it is an answer to a press, and ten servers' worth of
    # card is not something to hand somebody who did not ask. A host still
    # holding an open chip from an earlier instance (the feed's card put away
    # and fetched back) hears so, or that chip would say "expanded" over nothing.
    if connected?(socket), do: notify({:panel, nil})

    {:ok, socket |> assign(open_id: nil, rows: [], typed: "", field_key: 0) |> answer(nil, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(:user, assigns.user) |> assign(:tags, assigns.tags)

    # A host hands a new list when its follow set changed: a tag that has just
    # been unfollowed has no panel to keep open, and one still followed is read
    # again.
    cond do
      is_nil(socket.assigns.open_id) -> {:ok, socket}
      open_tags(socket.assigns.open_id, assigns.tags) == [] -> {:ok, close(socket)}
      true -> {:ok, assign_rows(socket)}
    end
  end

  # The chip: open this tag's panel, or close it if it is the one already open.
  @impl true
  def handle_event("tag-sources", %{"id" => tag_id}, socket) do
    if socket.assigns.open_id == tag_id do
      {:noreply, close(socket)}
    else
      {:noreply, open(socket, tag_id)}
    end
  end

  def handle_event("tag-sources-close", _params, socket) do
    {:noreply, close(socket)}
  end

  # Switching an offered server on. The offer itself is not the permission: the
  # row is re-derived from the database and the last probe, so a stale panel
  # (the operator blocked the server while it was open, the probe has since
  # gone stale) cannot be pressed into an add the check would refuse.
  def handle_event("tag-source-add", %{"source" => host}, socket) do
    {:noreply, add_source(socket, host, false)}
  end

  # A typed address, which nothing has vetted yet — the same gate, which for a
  # server nobody has asked before means a real probe. Only this path says
  # "taken" in words: a switch that flips is its own answer.
  def handle_event("tag-source-check", %{"source" => typed}, socket) do
    case String.trim(to_string(typed)) do
      "" -> {:noreply, socket}
      value -> {:noreply, add_source(socket, value, true)}
    end
  end

  # Clears the success line too: it would go on naming a server that no longer
  # feeds the tag.
  def handle_event("tag-source-remove", %{"source" => host}, socket) do
    case open_follow(socket) do
      nil ->
        {:noreply, close(socket)}

      follow ->
        Tags.remove_tag_follow_source(follow, host)
        {:noreply, socket |> answer(nil, nil) |> sources_changed()}
    end
  end

  # What the panel asked the other servers, arriving behind the already-drawn
  # panel. The rows are re-derived from the database rather than from what the
  # task returned, so a source added or dropped while it was in flight is not
  # overwritten by an older picture; a panel closed or switched to another tag
  # meanwhile simply has nothing to redraw.
  @impl true
  def handle_async(:tag_server_infos, {:ok, _infos}, socket) do
    if socket.assigns.open_id do
      {:noreply, assign_rows(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:tag_server_infos, {:exit, reason}, socket) do
    Logger.warning("tag source refresh failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Every chip names this id as its `phx-target`: the chip is the host's
    markup, so a selector is the only way it reaches the one panel on a page. --%>
    <div id="tag-sources">
      <%!-- A one-or-none comprehension rather than an `:if` beside a second
      lookup: the open tag has to be found, and finding it twice per render is
      what an `:if={find(...)} tag={find(...)}` pair costs. --%>
      <.source_panel
        :for={tag <- open_tags(@open_id, @tags)}
        tag={tag}
        rows={@rows}
        error={@error}
        added={@added}
        typed={@typed}
        field_key={@field_key}
        target={@myself}
      />
    </div>
    """
  end

  defp open(socket, tag_id) do
    case open_tags(tag_id, socket.assigns.tags) do
      [] ->
        close(socket)

      [tag] ->
        notify({:panel, tag_id})

        socket
        |> assign(:open_id, tag_id)
        |> answer(nil, nil)
        |> assign(:typed, "")
        |> assign_rows()
        |> ask_stale_servers(tag)
    end
  end

  defp close(socket) do
    notify({:panel, nil})

    socket
    |> assign(:open_id, nil)
    |> assign(:rows, [])
    |> answer(nil, nil)
    |> assign(:typed, "")
  end

  # What the panel last said about a press: a refusal or the host a typed
  # address was taken as. One at a time, so a refusal never stands under a
  # success it has just overtaken.
  defp answer(socket, error, added) do
    socket |> assign(:error, error) |> assign(:added, added)
  end

  # The open tag, as a one-or-none list.
  defp open_tags(nil, _tags), do: []

  defp open_tags(id, tags) do
    case Enum.find(tags, &(&1.id == id)) do
      nil -> []
      tag -> [tag]
    end
  end

  # The open panel's own follow, read fresh. Only one tag's sources are ever on
  # screen, so this asks for one follow's rather than every followed tag's.
  defp open_follow(socket) do
    Tags.tag_follow(socket.assigns.user, socket.assigns.open_id)
  end

  defp assign_rows(socket) do
    sources =
      case open_follow(socket) do
        nil -> []
        follow -> Tags.tag_follow_sources(follow)
      end

    assign(socket, :rows, SourceServers.rows(sources))
  end

  defp sources_changed(socket) do
    notify({:sources_changed, socket.assigns.open_id})
    assign_rows(socket)
  end

  # A component runs in its host's process, so `self()` is the host.
  defp notify(message), do: send(self(), {__MODULE__, message})

  # The panel opens on what is already stored and fills in behind itself. Asking
  # ten servers is three requests each and seconds of wall clock, and a member
  # who pressed a chip is owed the panel now — so nothing here blocks the render,
  # and a server nobody has ever asked simply reads "not asked yet" until the
  # answer lands. Nothing is asked at all when every row is fresh, which is the
  # ordinary case after the first press of the day.
  defp ask_stale_servers(socket, tag) do
    stale =
      socket.assigns.rows
      |> Enum.reject(&(&1.local? or SourceServers.fresh?(&1.info)))
      |> Enum.map(& &1.host)

    if stale == [] do
      socket
    else
      start_async(socket, :tag_server_infos, fn -> SourceServers.refresh(stale, tag) end)
    end
  end

  # One way in for both the offered switches and the typed field: the address is
  # put through `SourceServers.check/2` and only then written. The panel's own
  # `disabled` is a courtesy, never the permission — it was rendered before the
  # press and the operator may have blocked the server in between.
  defp add_source(socket, value, confirm?) do
    with [tag] <- open_tags(socket.assigns.open_id, socket.assigns.tags),
         %{} = follow <- open_follow(socket),
         {:ok, host} <- SourceServers.check(value, tag),
         {:ok, _row} <- Tags.add_tag_follow_source(follow, host) do
      socket
      |> answer(nil, if(confirm?, do: host))
      |> field(confirm?, :added)
      |> sources_changed()
    else
      # The panel is open on a tag this member no longer follows.
      [] -> close(socket)
      nil -> close(socket)
      {:error, reason} -> socket |> answer(reason, nil) |> field(confirm?, value)
    end
  end

  # The typed field after its own press. LiveView leaves a focused input's value
  # alone on a patch and resets an unfocused one to what is rendered, so the
  # text is rendered back on a refusal (the member corrects it, whether Return
  # or the button sent it) and an add renders the field under a new id, which
  # the client swaps for an empty element rather than patching the old one, at
  # the price of the focus.
  defp field(socket, false, _outcome), do: socket

  defp field(socket, true, :added) do
    socket |> assign(:typed, "") |> update(:field_key, &(&1 + 1))
  end

  defp field(socket, true, typed), do: assign(socket, :typed, typed)

  @doc """
  The number on one followed tag's chip, and the way into changing it.

  `count` comes from the caller so the value is read once per chip rather than
  three times inside the markup. The press goes to the page's one panel.

  A bordered pill with a globe and the number, so it reads as something to
  press rather than as a badge (issue #2166). `size` is the host's line:

    * `:rail` (the feed's tag chips) is exactly the tag chip's own 20px text
      line tall, so the chip row keeps the rhythm #2180 gave it;
    * `:touch` (the tag page) draws the tag follow pill's 30px box and gives it
      a 40px target around it, overflowing the 30px line its host holds for it.
  """
  attr(:tag, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:open?, :boolean, required: true)
  attr(:size, :atom, default: :rail, values: [:rail, :touch])

  def source_chip(assigns) do
    ~H"""
    <button
      id={"tag-sources-chip-#{@tag.id}"}
      type="button"
      phx-click="tag-sources"
      phx-target="#tag-sources"
      phx-value-id={@tag.id}
      aria-expanded={to_string(@open?)}
      title={gettext("Choose which servers this tag comes from")}
      aria-label={
        ngettext(
          "%{tag} comes from %{formatted} server. Change that.",
          "%{tag} comes from %{formatted} servers. Change that.",
          @count,
          tag: tag_name(@tag),
          formatted: compact_count(@count)
        )
      }
      class={source_chip_class(@size)}
    >
      <span class={source_chip_face_class(@size)}>
        <.detail_icon name="globe" class={if(@size == :rail, do: "h-3 w-3", else: "h-4 w-4")} />
        <span aria-hidden="true">{compact_count(@count)}</span>
      </span>
    </button>
    """
  end

  # The button is the target, the inner span the pill a reader sees: at rail
  # scale the two are one box, on the tag page the target is the taller one.
  defp source_chip_class(:rail), do: "group flex-shrink-0 rounded-full focus-visible:outline-none"

  defp source_chip_class(:touch),
    do: "group flex h-10 flex-shrink-0 items-center rounded-full focus-visible:outline-none"

  @chip_face "inline-flex items-center rounded-full border font-semibold transition-colors " <>
               "border-brand-300 bg-white text-brand-700 " <>
               "group-hover:border-brand-500 group-hover:bg-brand-100 group-hover:text-brand-900 " <>
               "group-focus-visible:ring-2 group-focus-visible:ring-brand-500 " <>
               "dark:border-brand-500 dark:bg-slate-900 dark:text-brand-100 " <>
               "dark:group-hover:border-brand-300 dark:group-hover:bg-brand-800 " <>
               "dark:group-hover:text-white dark:group-focus-visible:ring-brand-300"

  defp source_chip_face_class(:rail), do: @chip_face <> " h-5 gap-0.5 px-1.5 text-xs leading-none"
  defp source_chip_face_class(:touch), do: @chip_face <> " gap-1 px-3 py-1.5 text-xs"

  attr(:tag, :map, required: true)
  attr(:rows, :list, required: true)
  attr(:error, :any, default: nil)
  attr(:added, :string, default: nil)
  attr(:typed, :string, default: "")
  attr(:field_key, :integer, default: 0)
  attr(:target, :any, required: true)

  defp source_panel(assigns) do
    {own_rows, listed_rows} = Enum.split_with(assigns.rows, & &1.own?)
    at_cap? = at_cap?(assigns.rows)
    enabled? = SourceServers.enabled?()

    assigns =
      assign(assigns,
        at_cap?: at_cap?,
        enabled?: enabled?,
        listed_rows: listed_rows,
        own_rows: own_rows,
        can_type?: enabled? and not at_cap?
      )

    ~H"""
    <div id="tag-sources-panel" class="mt-3 border-t border-slate-200 pt-3 dark:border-slate-700">
      <div class="flex items-start justify-between gap-2">
        <h3 class="text-sm font-bold text-slate-900 dark:text-white">
          {gettext("Where should %{tag} come from?", tag: "#" <> tag_name(@tag))}
        </h3>
        <button
          id="tag-sources-close"
          type="button"
          phx-click="tag-sources-close"
          phx-target={@target}
          aria-label={gettext("Close the server list")}
          class="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-full leading-none text-slate-500 transition hover:bg-slate-100 hover:text-slate-800 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"
        >
          <span aria-hidden="true">×</span>
        </button>
      </div>

      <%!-- The sentence that makes the vutuv row's dead switch honest rather
      than broken: it is on because it cannot be anything else. --%>
      <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {gettext(
          "vutuv is always on. Every other server brings the posts on #%{tag} that it sees in the fediverse.",
          tag: tag_name(@tag)
        )}
      </p>

      <p :if={not @enabled?} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {gettext("This installation does not read other servers.")}
      </p>

      <%!-- Directly above the switches it greys out, which name it. --%>
      <p
        :if={@at_cap?}
        id="tag-sources-cap"
        class="mt-2 text-xs font-semibold text-slate-700 dark:text-slate-300"
      >
        {error_text(:too_many_sources, @tag)}
      </p>
      <ul id="tag-source-rows" class="mt-2">
        <.row :for={row <- @listed_rows} row={row} tag={@tag} at_cap?={@at_cap?} target={@target} />
      </ul>

      <%!-- What the member typed in, and the field they typed it into, as one
      block: a server taken from the field shows up where the eye already is. A
      picked server is always on, so the cap never greys these out. --%>
      <div :if={@own_rows != [] or @can_type?} id="tag-source-own" class="mt-3">
        <ul
          :if={@own_rows != []}
          id="tag-source-own-rows"
          class="mb-2 border-t border-slate-100 dark:border-slate-800"
        >
          <.row :for={row <- @own_rows} row={row} tag={@tag} at_cap?={@at_cap?} target={@target} />
        </ul>
        <%!-- Issue #2174: only a server the operator listed relays other
        servers' posts, and the member should know before typing one. --%>
        <p
          :if={@enabled?}
          id="tag-source-own-members"
          class="mb-1.5 text-xs text-slate-500 dark:text-slate-400"
        >
          {gettext("A server you add yourself only brings posts by its own members.")}
        </p>
        <%!-- Not `<.rail_add_field>`: that is a `+` which opens one field, and a
        second `+` inside an already-opened disclosure reads as another thing to
        unfold. The field's recipe is still the rail's own, so it cannot drift
        from the one above it. --%>
        <form
          :if={@can_type?}
          id="tag-source-form"
          phx-submit="tag-source-check"
          phx-target={@target}
        >
          <label for={"tag-source-input-#{@field_key}"} class="sr-only">
            {gettext("Add another server")}
          </label>
          <input
            id={"tag-source-input-#{@field_key}"}
            type="text"
            name="source"
            value={@typed}
            maxlength="255"
            placeholder={gettext("Add another server")}
            aria-describedby="tag-source-own-members"
            class={rail_field_class()}
          />
          <.button type="submit" class="mt-1.5 w-full">{gettext("Check and add")}</.button>
        </form>
      </div>

      <%!-- Always rendered, so a screen reader is already watching the region
      when something is said into it; the two lines never stand together. --%>
      <div id="tag-sources-status" role="status" aria-live="polite" class="text-xs font-semibold">
        <p :if={@added} id="tag-sources-added" class="mt-2 text-emerald-700 dark:text-emerald-400">
          {gettext("%{host} now feeds #%{tag}.", host: @added, tag: tag_name(@tag))}
        </p>
        <p :if={@error} id="tag-sources-error" class="mt-2 text-rose-600 dark:text-rose-400">
          {error_text(@error, @tag)}
        </p>
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:tag, :map, required: true)
  attr(:at_cap?, :boolean, required: true)
  attr(:target, :any, required: true)

  # Each of the four things a row says is derived once here rather than twice in
  # the markup, where a `:if` and the value beside it would each call the helper
  # — and three of the four go through gettext.
  defp row(assigns) do
    assigns =
      assigns
      |> assign(:badge, badge(assigns.row))
      |> assign(:description, description(assigns.row))
      |> assign(:note, note(assigns.row, assigns.tag))
      |> assign(:figures, figures(assigns.row))

    ~H"""
    <li
      id={"tag-source-#{dom_key(@row.host)}"}
      data-host={@row.host}
      class="flex items-start gap-2 border-t border-slate-100 py-2 first:border-t-0 dark:border-slate-800"
    >
      <.switch row={@row} at_cap?={@at_cap?} note?={@note != nil} target={@target} />
      <div class="min-w-0 flex-1">
        <p class="flex flex-wrap items-center gap-1.5">
          <span class="text-sm font-semibold text-slate-900 dark:text-white">{@row.host}</span>
          <span
            :if={@badge}
            class="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-600 dark:bg-slate-800 dark:text-slate-300"
          >
            {@badge}
          </span>
        </p>
        <p
          :if={@description}
          class="mt-0.5 line-clamp-3 text-xs text-slate-600 dark:text-slate-400"
        >
          {@description}
        </p>
        <p
          :if={@figures != []}
          class="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-slate-500 dark:text-slate-400"
        >
          <span :for={{label, value} <- @figures}>
            {label}
            <span class="font-semibold text-slate-800 dark:text-slate-200">{value}</span>
          </span>
        </p>
        <p
          :if={@note}
          id={"tag-source-note-#{dom_key(@row.host)}"}
          class="mt-1 text-xs text-slate-500 dark:text-slate-400"
        >
          {@note}
        </p>
      </div>
    </li>
    """
  end

  attr(:row, :map, required: true)
  attr(:at_cap?, :boolean, required: true)
  attr(:note?, :boolean, required: true)
  attr(:target, :any, required: true)

  defp switch(assigns) do
    # `assign/3`, not `Map.put/3`: these change whenever the row does, and a
    # value put straight into the map carries no change-tracking entry — so the
    # attributes reading it are never re-sent, and a switch that has just become
    # pickable stays `disabled` on screen while every figure beside it updates.
    %{row: row, at_cap?: at_cap?} = assigns
    switchable? = switchable?(row, at_cap?)

    assigns =
      assigns
      |> assign(:switchable?, switchable?)
      |> assign(:reasons, off_reasons(row, switchable?, at_cap?, assigns.note?))

    ~H"""
    <%!-- A real switch, so a screen reader is told this is a two-state control
    and which state it is in. --%>
    <button
      id={"tag-source-switch-#{dom_key(@row.host)}"}
      type="button"
      role="switch"
      aria-checked={to_string(@row.picked?)}
      aria-label={switch_label(@row)}
      aria-describedby={@reasons}
      disabled={not @switchable?}
      phx-click={if(@row.picked?, do: "tag-source-remove", else: "tag-source-add")}
      phx-target={@target}
      phx-value-source={@row.host}
      class="flex h-10 w-12 flex-shrink-0 items-center justify-center disabled:cursor-not-allowed"
    >
      <span
        aria-hidden="true"
        class={[
          "relative block h-6 w-11 rounded-full transition",
          @row.picked? && not @switchable? && "bg-brand-300 dark:bg-brand-700",
          @row.picked? && @switchable? && "bg-brand-600 dark:bg-brand-500",
          not @row.picked? && "bg-slate-200 dark:bg-slate-700",
          not @row.picked? && not @switchable? && "opacity-50"
        ]}
      >
        <span class={[
          "absolute top-0.5 block h-5 w-5 rounded-full bg-white shadow transition-all",
          if(@row.picked?, do: "left-[1.375rem]", else: "left-0.5")
        ]}>
        </span>
      </span>
    </button>
    """
  end

  # The ids of what says why a switch cannot be turned on, or nil for one that
  # can: the cap first, then the row's own note. vutuv's switch is described by
  # its label already, and a switch that is on is never held back.
  defp off_reasons(%{local?: true}, _switchable?, _at_cap?, _note?), do: nil
  defp off_reasons(_row, true, _at_cap?, _note?), do: nil

  defp off_reasons(row, false, at_cap?, note?) do
    [at_cap? && "tag-sources-cap", note? && "tag-source-note-#{dom_key(row.host)}"]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  @doc """
  Whether the follow behind `rows` may name another server.

  Read off the rendered rows rather than counted a second time in the socket, so
  the message and the `disabled` attributes can never disagree with the list the
  reader is looking at.
  """
  def at_cap?(rows) do
    Enum.count(rows, &(&1.picked? and not &1.local?)) >= SourceServers.limit()
  end

  # A hostname is not a DOM id: `#tag-source-mastodon.social` reads as an id
  # plus a class to every CSS selector, this app's own tests included.
  defp dom_key(host), do: String.replace(host, ".", "-")

  # vutuv is never switchable. Everything else may be switched off whenever it
  # is on, and switched on only when the last probe said the timeline is public,
  # the operator has not blocked it, and the follow has room. This is the view's
  # copy of a decision `SourceServers.check/2` makes again on the press — it
  # decides what the control looks like, never what is allowed.
  defp switchable?(%{local?: true}, _at_cap?), do: false
  defp switchable?(%{picked?: true}, _at_cap?), do: true
  defp switchable?(_row, true), do: false

  defp switchable?(row, _at_cap?) do
    not row.blocked? and SourceServer.pickable?(row.info)
  end

  defp switch_label(%{local?: true}), do: gettext("vutuv cannot be switched off")

  defp switch_label(%{picked?: true, host: host}),
    do: gettext("Stop reading %{host}", host: host)

  defp switch_label(%{host: host}), do: gettext("Also read %{host}", host: host)

  defp badge(%{local?: true}), do: gettext("here")
  defp badge(%{info: %{language: code}}) when is_binary(code), do: String.upcase(code)
  defp badge(_row), do: nil

  defp description(%{local?: true}) do
    gettext("Posts by members and pages here. That is how it was, and how it stays by itself.")
  end

  defp description(%{info: %{description: text}}) when is_binary(text), do: text
  defp description(_row), do: nil

  # Accounts and the month's active accounts are figures a reader compares, so
  # they are grouped exactly; the post count is a magnitude and reads as one.
  defp figures(%{local?: true}), do: []

  defp figures(%{info: %{} = info}) do
    [
      {gettext("Accounts"), info.accounts && delimited_count(info.accounts)},
      {gettext("Active this month"), info.active_month && delimited_count(info.active_month)},
      {gettext("Posts"), info.posts && compact_count(info.posts)}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp figures(_row), do: []

  # The same sentences the typed field's refusals use, with the row's host in
  # them — one msgid per thing that can be wrong, said the same way wherever it
  # is said.
  defp note(%{local?: true}, _tag), do: gettext("vutuv cannot be switched off.")
  defp note(%{blocked?: true, host: host}, tag), do: error_text({:blocked, host}, tag)

  defp note(%{info: %{status: "account_required"}, host: host}, tag),
    do: error_text({:account_required, host}, tag)

  defp note(%{info: %{status: "unreachable"}, host: host}, tag),
    do: error_text({:unreachable, host}, tag)

  defp note(%{info: %{status: "ok"}}, _tag), do: nil
  defp note(_row, _tag), do: gettext("Not asked yet.")

  @doc """
  Every refusal `Vutuv.Tags.SourceServers.check/2` can answer with, plus the
  cap, said to the member rather than logged, about the open `tag`.

  The host comes back inside the refusal, in the spelling it would be stored
  under, so a typo is easy to see beside what it was read as — and so nothing
  here has to normalize an address a second time to guess it.

  The tag is named with its hash wherever a sentence is about it (issue #2166):
  German calls this feature "das Tag", and a compound like "Tag-Zeitleiste"
  reads as a *day*.
  """
  def error_text({:account_required, host}, tag) do
    gettext("%{host} only shows posts on #%{tag} to people who have an account there.",
      host: host,
      tag: tag_name(tag)
    )
  end

  def error_text(reason, _tag), do: refusal(reason)

  defp refusal({:not_a_server, typed}),
    do: gettext("%{typed} is not a server name.", typed: typed)

  defp refusal(:insecure), do: gettext("Only an https address can be added.")

  defp refusal(:local), do: gettext("That is this installation, and it is always on anyway.")

  defp refusal({:blocked, host}),
    do: gettext("This installation has shut %{host} out.", host: host)

  defp refusal({:internal, host}),
    do: gettext("%{host} is not an address this installation may read.", host: host)

  defp refusal({reason, host}) when reason in [:unreachable, :unresolvable],
    do: gettext("%{host} did not answer.", host: host)

  defp refusal({:busy, _host}), do: refusal(:busy)
  defp refusal(:busy), do: gettext("Busy right now — please try again in a moment.")
  defp refusal(:disabled), do: gettext("This installation does not read other servers.")

  defp refusal(:too_many_sources) do
    ngettext(
      "You can choose up to %{formatted} other server. To pick a different one, switch one off first.",
      "You can choose up to %{formatted} other servers. To pick a different one, switch one off first.",
      SourceServers.limit(),
      formatted: compact_count(SourceServers.limit())
    )
  end

  defp refusal(_other), do: gettext("That did not work.")

  defp tag_name(tag), do: tag.name || tag.slug
end
