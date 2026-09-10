defmodule VutuvWeb.PostLive.TagSources do
  @moduledoc """
  "Where should #tag come from?" — the chip on every followed tag in the feed's
  tag card, and the panel it opens (issue #2128).

  A followed tag has carried its sources since #2125 and has been pulling from
  them since #2126, with nothing anywhere saying so. This is the first thing a
  member can see and change about them: a number saying how many servers feed
  the tag, and a list of servers with their size beside them.

  ## Why it is a panel in the card and not a dialog

  This app has no dialogs. The disclosure is how everything else here opens, and
  a panel that appears where the chip was pressed keeps the tag it is about on
  screen. The card lives in the feed's rail, which is `hidden md:block`, so this
  is a desktop surface for now — a phone has no tag card to hang it off yet.

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

  Everything else it draws is a row from `Vutuv.Tags.SourceServers.rows/1`; the
  events that change them live in `VutuvWeb.PostLive.Feed`, where the socket is.
  """

  use VutuvWeb, :html

  import VutuvWeb.PostComponents, only: [rail_field_class: 0]

  alias Vutuv.Tags.SourceServer
  alias Vutuv.Tags.SourceServers

  @doc """
  The number on one followed tag's chip, and the way into changing it.

  `count` comes from the caller so the value is read once per chip rather than
  three times inside the markup.
  """
  attr(:tag, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:open?, :boolean, required: true)

  def source_chip(assigns) do
    ~H"""
    <button
      id={"tag-sources-chip-#{@tag.id}"}
      type="button"
      phx-click="tag-sources"
      phx-value-id={@tag.id}
      aria-expanded={to_string(@open?)}
      aria-label={
        ngettext(
          "%{tag} comes from %{formatted} server. Change that.",
          "%{tag} comes from %{formatted} servers. Change that.",
          @count,
          tag: @tag.name || @tag.slug,
          formatted: compact_count(@count)
        )
      }
      class="flex h-4 min-w-4 flex-shrink-0 items-center justify-center rounded-full bg-brand-100 px-1 text-[10px] font-semibold leading-none text-brand-700 transition hover:bg-brand-200 hover:text-brand-900 dark:bg-brand-700 dark:text-brand-50 dark:hover:bg-brand-600"
    >
      <span aria-hidden="true">{compact_count(@count)}</span>
    </button>
    """
  end

  attr(:tag, :map, required: true)
  attr(:rows, :list, required: true)
  attr(:error, :any, default: nil)

  def source_panel(assigns) do
    assigns = assign(assigns, :at_cap?, at_cap?(assigns.rows))

    ~H"""
    <div id="tag-sources-panel" class="mt-3 border-t border-slate-200 pt-3 dark:border-slate-700">
      <div class="flex items-start justify-between gap-2">
        <h3 class="text-sm font-bold text-slate-900 dark:text-white">
          {gettext("Where should %{tag} come from?", tag: "#" <> (@tag.name || @tag.slug))}
        </h3>
        <button
          id="tag-sources-close"
          type="button"
          phx-click="tag-sources-close"
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
          "vutuv is always on. Every other server delivers the same tag as it sees the fediverse."
        )}
      </p>

      <p :if={not SourceServers.enabled?()} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {gettext("This installation does not read other servers.")}
      </p>

      <ul id="tag-source-rows" class="mt-2">
        <.row :for={row <- @rows} row={row} at_cap?={@at_cap?} />
      </ul>

      <p :if={@at_cap?} id="tag-sources-cap" class="mt-2 text-xs text-slate-500 dark:text-slate-400">
        {error_text(:too_many_sources)}
      </p>

      <%!-- Not `<.rail_add_field>`: that is a `+` which opens one field, and a
      second `+` inside an already-opened disclosure reads as another thing to
      unfold. The field's recipe is still the rail's own, so it cannot drift
      from the one above it. --%>
      <form
        :if={SourceServers.enabled?() and not @at_cap?}
        id="tag-source-form"
        phx-submit="tag-source-check"
        class="mt-3"
      >
        <label for="tag-source-input" class="sr-only">{gettext("Add another server")}</label>
        <input
          id="tag-source-input"
          type="text"
          name="source"
          value=""
          maxlength="255"
          placeholder={gettext("Add another server")}
          class={rail_field_class()}
        />
        <.button type="submit" class="mt-1.5 w-full">{gettext("Check and add")}</.button>
      </form>

      <p
        :if={@error}
        id="tag-sources-error"
        class="mt-2 text-xs font-semibold text-rose-600 dark:text-rose-400"
      >
        {error_text(@error)}
      </p>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:at_cap?, :boolean, required: true)

  # Each of the four things a row says is derived once here rather than twice in
  # the markup, where a `:if` and the value beside it would each call the helper
  # — and three of the four go through gettext.
  defp row(assigns) do
    assigns =
      assigns
      |> assign(:badge, badge(assigns.row))
      |> assign(:description, description(assigns.row))
      |> assign(:note, note(assigns.row))
      |> assign(:figures, figures(assigns.row))

    ~H"""
    <li
      id={"tag-source-#{dom_key(@row.host)}"}
      data-host={@row.host}
      class="flex items-start gap-2 border-t border-slate-100 py-2 first:border-t-0 dark:border-slate-800"
    >
      <.switch row={@row} at_cap?={@at_cap?} />
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
        <p :if={@note} class="mt-1 text-xs text-slate-500 dark:text-slate-400">{@note}</p>
      </div>
    </li>
    """
  end

  attr(:row, :map, required: true)
  attr(:at_cap?, :boolean, required: true)

  defp switch(assigns) do
    # `assign/3`, not `Map.put/3`: this changes whenever the row does, and a
    # value put straight into the map carries no change-tracking entry — so the
    # attributes reading it are never re-sent, and a switch that has just become
    # pickable stays `disabled` on screen while every figure beside it updates.
    assigns = assign(assigns, :switchable?, switchable?(assigns.row, assigns.at_cap?))

    ~H"""
    <%!-- A real switch, so a screen reader is told this is a two-state control
    and which state it is in. --%>
    <button
      id={"tag-source-switch-#{dom_key(@row.host)}"}
      type="button"
      role="switch"
      aria-checked={to_string(@row.picked?)}
      aria-label={switch_label(@row)}
      disabled={not @switchable?}
      phx-click={if(@row.picked?, do: "tag-source-remove", else: "tag-source-add")}
      phx-value-source={@row.host}
      class="flex h-10 w-12 flex-shrink-0 items-center justify-center disabled:cursor-not-allowed"
    >
      <span
        aria-hidden="true"
        class={[
          "relative block h-6 w-11 rounded-full transition",
          @row.picked? && not @switchable? && "bg-brand-300 dark:bg-brand-700",
          @row.picked? && @switchable? && "bg-brand-600 dark:bg-brand-500",
          not @row.picked? && "bg-slate-200 dark:bg-slate-700"
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
  defp note(%{local?: true}), do: gettext("vutuv cannot be switched off.")
  defp note(%{blocked?: true, host: host}), do: error_text({:blocked, host})

  defp note(%{info: %{status: "account_required"}, host: host}),
    do: error_text({:account_required, host})

  defp note(%{info: %{status: "unreachable"}, host: host}), do: error_text({:unreachable, host})
  defp note(%{info: %{status: "ok"}}), do: nil
  defp note(_row), do: gettext("Not asked yet.")

  @doc """
  Every refusal `Vutuv.Tags.SourceServers.check/2` can answer with, plus the
  cap, said to the member rather than logged.

  The host comes back inside the refusal, in the spelling it would be stored
  under, so a typo is easy to see beside what it was read as — and so nothing
  here has to normalize an address a second time to guess it.
  """
  def error_text({:not_a_server, typed}),
    do: gettext("%{typed} is not a server name.", typed: typed)

  def error_text(:insecure), do: gettext("Only an https address can be added.")

  def error_text(:local), do: gettext("That is this installation, and it is always on anyway.")

  def error_text({:blocked, host}),
    do: gettext("This installation has shut %{host} out.", host: host)

  def error_text({:account_required, host}) do
    gettext("%{host} shows its tag timeline only to somebody with an account there.", host: host)
  end

  def error_text({:internal, host}),
    do: gettext("%{host} is not an address this installation may read.", host: host)

  def error_text({reason, host}) when reason in [:unreachable, :unresolvable],
    do: gettext("%{host} did not answer.", host: host)

  def error_text({:busy, _host}), do: error_text(:busy)
  def error_text(:busy), do: gettext("Busy right now — please try again in a moment.")
  def error_text(:disabled), do: gettext("This installation does not read other servers.")

  def error_text(:too_many_sources) do
    ngettext(
      "A tag may name %{formatted} other server. Switch one off to pick another.",
      "A tag may name %{formatted} other servers. Switch one off to pick another.",
      SourceServers.limit(),
      formatted: compact_count(SourceServers.limit())
    )
  end

  def error_text(_other), do: gettext("That did not work.")
end
