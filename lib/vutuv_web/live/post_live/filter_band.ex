defmodule VutuvWeb.PostLive.FilterBand do
  @moduledoc """
  The feed's filter band: the rail card that replaces the All / vutuv /
  Fediverse tabs.

  The tabs made the source question a *place* — choosing one hid the other and
  the coral dot on the tab you left kept telling you what you were missing, so
  the reader hopped back and forth. The band makes it a *state* instead: one
  timeline that shows everything by default, with a checkbox per account, per
  fediverse server and per source to switch off what they do not want. Nothing
  here is a new mechanism — a member checkbox writes `follows.muted`, a remote
  one `fediverse_follows.muted`, a server `users.feed_muted_hosts`
  (`Vutuv.Fediverse.set_host_mute/3`), and the two source rows write the very
  column the tabs used (`users.feed_source`), which is why the tabs can leave
  without their state going with them.

  Every switch is therefore **permanent** and shared across the member's
  devices, and the band says so in its own subtitle: what you switch off here
  stays off tomorrow, and this is the one place to switch it back on. That is
  also why a muted account keeps its row (`Vutuv.FeedBand` adds it past the
  cap) — a list that hides what you silenced offers no way back.

  The component owns only what a reload may forget: the sort, the search text,
  which branches are open. Everything it *changes* it writes through those
  contexts and then hands the fresh `%User{}` up to the feed
  (`{:filter_band, :changed, user}`), which re-runs its page — the band must
  never hold a second copy of the truth the feed reads.
  """
  use VutuvWeb, :live_component

  import VutuvWeb.PostComponents, only: [rail_add_field: 1, rail_field_class: 0]

  alias Vutuv.ContentFilters
  alias Vutuv.ContentFilters.ContentFilter
  alias Vutuv.Fediverse
  alias Vutuv.FeedBand
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.Social
  alias VutuvWeb.PostTeaser

  # How many accounts the vutuv branch lists before "search all of them".
  @top_accounts 6
  # How many of the hits the word preview quotes. Three is a sample, not a
  # list: the count beside it carries the rest, and a rail card is no place for
  # a second timeline.
  @preview_quotes 3
  # How many servers the fediverse branch lists before "show more", and how many
  # accounts each one lists before the same.
  @top_servers 5
  @top_server_accounts 6

  @impl true
  def mount(socket) do
    {:ok,
     socket
     # `closed` rather than `open`, and it starts empty: every branch and every
     # server ships EXPANDED. The fediverse half used to stop at its servers and
     # hide the accounts behind a small grey triangle, while the vutuv half put
     # its accounts straight on the page — the same question answered at two
     # different depths, and only one of them findable (Stefan, 2026-08-28).
     # `full` holds the servers whose account list is shown past its cap.
     |> assign(sort: :active, query: "", twisted: MapSet.new(), full: MapSet.new())
     |> assign(more_accounts?: false, more_servers?: false)
     # What the last bulk press overwrote, or nil. It lives in the socket and
     # not in a column on purpose: this is an undo of the act you just made, not
     # a history, and a reload is itself an answer to "did I mean that".
     |> assign(undo: nil)
     |> assign(loaded?: false)
     # The rule being typed: the word or tag, and the accounts it is aimed at.
     # Blank is the ordinary answer to the second — a rule with no account named
     # reads every account, exactly as every rule did before there was one.
     |> assign(word_draft: "", word_account: "", tag_draft: "", tag_account: "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  # Which halves the two source rows show as on. It comes from the feed, not
  # from `users.feed_source`, because the two can legitimately differ: when the
  # member posts something their own filter would hide, the feed pulls itself
  # back to both halves without touching the stored choice — that pull is the
  # code's doing, not theirs, and the next visit still opens where they left
  # off. A band reading the column would then tick a box the timeline is not
  # obeying.

  # Everything the band reads. Re-read after every change it makes, because the
  # numbers beside the rows are the point of the thing: a switch that leaves a
  # stale count behind reads as a switch that did nothing.
  #
  # Each card loads only its own share: the three are separate blocks in the
  # rail now (the reader arranges them individually), so one instance per card
  # is mounted and a shared load would run the account and server queries three
  # times over for the two cards that never look at them.
  # Sources is the one block whose data costs real queries (the ranked
  # followee list alone reads every follow the member has), so it is loaded
  # more carefully than its two cheap siblings. Two gates. The dead render
  # skips the queries outright and draws the skeleton in `render/1`; the
  # connected mount loads the real thing (the folded card never renders the
  # component at all, so the default arrangement costs nothing either way).
  # And once loaded, a parent re-render that changed nothing the card reads —
  # "Load more" replacing `entries` is the common one — keeps the data it has:
  # only a fresh member handed back after a band write (`changed/1` forces the
  # reload anyway — a mute lands in `follows`, not on the user row, so the
  # struct alone cannot be trusted to differ), a source switch, or the feed
  # announcing an outside follow-state change through `refresh` re-runs them.
  defp load(%{assigns: %{block: :sources}} = socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :loaded?, false)

      socket.assigns.loaded? and
          not (changed?(socket, :current_user) or changed?(socket, :filter) or
                   changed?(socket, :refresh)) ->
        socket

      true ->
        socket |> assign(:loaded?, true) |> load_sources()
    end
  end

  defp load(%{assigns: %{block: :words}} = socket) do
    socket
    |> assign(:words, filters_of_kind(socket, :keyword))
    |> assign(:preview, preview(socket))
  end

  defp load(%{assigns: %{block: :tags}} = socket) do
    filters = ContentFilters.list_for_user(socket.assigns.current_user)

    socket
    |> assign(:muted_tags, Enum.filter(filters, &(&1.kind == :tag)))
    |> assign(:tag_suggestions, tag_suggestions(socket, filters))
  end

  defp load_sources(socket) do
    user = socket.assigns.current_user
    query = socket.assigns.query
    searching? = String.trim(query) != ""

    accounts =
      FeedBand.accounts(user,
        sort: socket.assigns.sort,
        query: query,
        # A search reaches past the resting cap on its own. It used to keep the
        # six-row limit with the "search all of them" link hidden, so looking
        # somebody up could answer with six of the eleven accounts that matched
        # and no way to see the rest.
        limit: if(searching? or socket.assigns.more_accounts?, do: 30, else: @top_accounts)
      )

    servers = FeedBand.servers(user, query: query)
    shown = shown_servers(servers, searching? or socket.assigns.more_servers?)

    # Read from the member, never off `servers`: that list is narrowed by the
    # search box, and a bulk switch that named only the hosts matching the
    # current search left every other one quietly on.
    hosts = FeedBand.hosts(user)
    muted_hosts = Fediverse.muted_hosts(user)

    socket
    |> assign(:accounts, accounts)
    |> assign(:servers, servers)
    |> assign(:hosts, hosts)
    |> assign(:anything_off?, muted_hosts != [] or FeedBand.accounts_muted?(user))
    |> assign(:all_off?, hosts -- muted_hosts == [])
    |> assign(:shown_servers, shown)
    |> assign(:hidden_servers, length(servers) - length(shown))
    |> assign(:searching?, searching?)
    |> assign(:account_count, FeedBand.account_count(user))
    |> assign(:vutuv_total, FeedBand.vutuv_total(user))
  end

  defp filters_of_kind(socket, kind) do
    socket.assigns.current_user
    |> ContentFilters.list_for_user()
    |> Enum.filter(&(&1.kind == kind))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} aria-busy={(@block == :sources and not @loaded?) && "true"}>
      <%!-- What the open card shows before its data is loaded (the dead
      render, and the moment before the socket is up): placeholder rows in the
      shape of the source rows — checkbox, name, count. `aria-busy` rides the
      component root above, the element that survives the swap, so assistive
      tech hears the busy state end. --%>
      <.skeleton_rows
        :if={@block == :sources and not @loaded?}
        id={@id <> "-skeleton"}
        rows={4}
        class="space-y-2 py-1"
        row_class="flex items-center gap-2"
      >
        <span class="skeleton h-5 w-5 shrink-0"></span>
        <span class="skeleton h-3 min-w-0 flex-1"></span>
        <span class="skeleton h-3 w-8"></span>
      </.skeleton_rows>

      <div :if={@block == :sources and @loaded?}>
        <%!-- The one thing a reader has to be told before they touch a switch:
        this is not an unfollow. Nothing here severs a relationship, and the
        other side is never told — a member checkbox writes `follows.muted`, a
        remote one `fediverse_follows.muted`, a server `feed_muted_hosts`. The
        old wording ("what you switch off here stays off") explained the
        permanence and left the reader to guess the rest, which is the half
        that would stop somebody using the card at all (Stefan, 2026-08-28). --%>
        <%!-- The promise, folded: four lines a reader takes in once and then
        scrolls past for the rest of their life with the card. --%>
        <details data-keep-open class="mb-3">
          <summary class="cursor-pointer list-none text-xs font-semibold text-brand-600 hover:text-brand-700 [&::-webkit-details-marker]:hidden dark:text-brand-400 dark:hover:text-brand-300">
            {gettext("What does switching off do?")}
          </summary>
          <p class="pt-1 text-xs text-slate-500 dark:text-slate-400">
            {gettext(
              "Switching off means muting, not unfollowing. You stay a follower, the posts just stop reaching your feed: permanently and on every device, until you switch them back on here."
            )}
          </p>
        </details>

        <%!-- One field for both halves. The reader's question is "where is that
        account", and they routinely do not know which half it lives on — so a
        search box per branch would make them guess, and a wrong guess answers
        "nothing found" (Stefan, 2026-08-28). It narrows the vutuv accounts in
        SQL and the fediverse servers and their accounts in memory, and while it
        is filled every cap is lifted and every branch is open: a search that
        stops at the sixth match is a search that hides the answer. --%>
        <form phx-change="search" phx-target={@myself} class="mb-3">
          <input
            type="search"
            name="query"
            value={@query}
            phx-debounce="300"
            placeholder={gettext("Find an account or a server …")}
            class="w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-sm text-slate-900 placeholder:text-slate-400 focus:border-brand-500 focus:outline-none dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100"
          />
        </form>

        <p
          :if={@searching? and @accounts == [] and @shown_servers == []}
          class="pb-2 text-xs text-slate-500 dark:text-slate-400"
        >
          {gettext("Nothing found — neither here nor on another server.")}
        </p>

        <.sources_list
          prefix={@id}
          target={@myself}
          servers={@servers}
          shown_servers={@shown_servers}
          hidden_servers={@hidden_servers}
          accounts={@accounts}
          account_count={@account_count}
          vutuv_total={@vutuv_total}
          filter={@filter}
          sort={@sort}
          full={@full}
          twisted={@twisted}
          searching?={@searching?}
          more_accounts?={@more_accounts?}
          anything_off?={@anything_off?}
          all_off?={@all_off?}
          undo?={@undo != nil}
        />
      </div>

      <%!-- Words and tags: the member's own deny list (issue #940), which has
      been complete since it shipped and invisible ever since — the table is
      empty in the development copy, because nobody finds /settings/filters. The
      block's heading says which way it cuts, because "Words" alone does not: a
      rule here HIDES, and a hit collapses the post to a line with a way back
      rather than dropping it out of the timeline. --%>
      <div :if={@block == :words}>
        <p class="mb-3 text-xs text-slate-500 dark:text-slate-400">
          {gettext(
            "Posts containing one of these are folded to a single line — not deleted, and with a way to open them anyway."
          )}
        </p>

        <div class="mb-2 flex flex-wrap items-start gap-2">
          <.filter_chip :for={filter <- @words} filter={filter} target={@myself} />

          <.rail_add_field
            label={gettext("Hide a word or a whole phrase …")}
            placeholder={gettext("Hide a word or a whole phrase …")}
            submit="add-word"
            change="word-draft"
            value={@word_draft}
            maxlength={ContentFilter.max_pattern()}
            target={@myself}
          >
            <:extra>
              <.account_scope_field value={@word_account} />
            </:extra>
          </.rail_add_field>
        </div>

        <%!-- What replaces a "whole words only" checkbox nobody could read: the
        rule's effect on the feed in front of the reader, as they type. It is
        also what lets the rule itself be permissive — see the `whole_word`
        comment on the write path below. --%>
        <p class="pt-2 text-xs text-slate-500 dark:text-slate-400">
          <%= cond do %>
            <% @preview == nil -> %>
              {gettext("Also inside longer words: %{word} catches %{example} too.",
                word: "Zeugnis",
                example: "Arbeitszeugnis"
              )}
              {gettext(
                "Leave the accounts empty and the rule reads everyone; %{example} narrows it to one server's accounts.",
                example: "*@social.heise.de"
              )}
            <% @preview.count == 0 -> %>
              {gettext("Matches nothing in your feed right now — the rule still holds for what comes next.")}
            <% true -> %>
              {ngettext(
                "Would fold %{formatted} post in your feed:",
                "Would fold %{formatted} posts in your feed:",
                @preview.count,
                formatted: delimited_count(@preview.count)
              )}
          <% end %>
        </p>

        <%!-- The hits themselves, so the reader can see whether the rule caught
        what they meant rather than trusting a number. Same pair of strings as
        the "not read yet" card (`VutuvWeb.PostTeaser`), so a post reads the
        same wherever it is quoted; deliberately not links, because this is a
        preview of a rule and not somewhere to go. --%>
        <ul :if={@preview && @preview.quotes != []} id={"#{@id}-hits"} class="mt-1 space-y-1">
          <li :for={quote <- @preview.quotes} class="min-w-0 text-xs">
            <%!-- The name is what a reader recognises; the handle beside it is
            the identity, and stays because two members share a name more often
            than two share a handle. Both on one truncating line: a hit is a
            glance, and the sentence below it is what the reader is checking. --%>
            <span class="flex min-w-0 items-baseline gap-1">
              <span :if={quote.name} class="min-w-0 truncate font-medium text-slate-700 dark:text-slate-200">
                {quote.name}
              </span>
              <span class="min-w-0 shrink truncate text-slate-500 dark:text-slate-400">
                {quote.handle}
              </span>
            </span>
            <span class="block truncate text-slate-700 dark:text-slate-300">
              {quote.text || gettext("A photo")}
            </span>
          </li>
        </ul>

        <p
          :if={@preview && @preview.count > length(@preview.quotes)}
          class="pt-1 text-xs text-slate-500 dark:text-slate-400"
        >
          {ngettext(
            "and 1 more",
            "and %{formatted} more",
            @preview.count - length(@preview.quotes),
            formatted: delimited_count(@preview.count - length(@preview.quotes))
          )}
        </p>
      </div>

      <div :if={@block == :tags}>
        <p class="mb-3 text-xs text-slate-500 dark:text-slate-400">
          {gettext("Posts carrying one of these tags are folded the same way.")}
        </p>

        <div class="mb-2 flex flex-wrap items-start gap-2">
          <.filter_chip :for={filter <- @muted_tags} filter={filter} target={@myself} />

          <.rail_add_field
            label={gettext("Hide a tag …")}
            placeholder={gettext("Hide a tag …")}
            submit="add-tag"
            change="tag-draft"
            value={@tag_draft}
            maxlength={ContentFilter.max_pattern()}
            target={@myself}
          >
            <:extra>
              <.account_scope_field value={@tag_account} />
            </:extra>
          </.rail_add_field>
        </div>

        <div :if={@tag_suggestions != []} class="pt-2">
          <p class="pb-1 text-xs text-slate-500 dark:text-slate-400">
            {gettext("In your feed right now:")}
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              :for={tag <- @tag_suggestions}
              type="button"
              phx-click="hide-tag"
              phx-value-pattern={tag}
              phx-target={@myself}
              class="rounded-lg bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
            >
              {tag}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  # Which accounts a rule being typed is aimed at. Inside the add field's own
  # form, so Return submits the pair; empty is every account, which is what the
  # placeholder says rather than a pre-filled `*` the reader has to delete.
  attr(:value, :string, required: true)

  defp account_scope_field(assigns) do
    ~H"""
    <input
      type="text"
      name="account"
      value={@value}
      maxlength={ContentFilter.max_pattern()}
      phx-debounce="300"
      placeholder={gettext("Only these accounts (empty = all) …")}
      class={[rail_field_class(), "mt-1.5"]}
    />
    """
  end

  attr(:filter, :map, required: true)
  attr(:target, :any, required: true)

  defp filter_chip(assigns) do
    ~H"""
    <span class="inline-flex max-w-full items-center gap-1 rounded-lg bg-brand-50 py-1 pl-3 pr-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100">
      <%!-- The scope under the word rather than beside it: a chip is already as
      wide as the card, and a rule reads "this word" first and "from these" second. --%>
      <span class="flex min-w-0 flex-col">
        <span class="min-w-0 truncate">{@filter.pattern}</span>
        <span
          :if={scope = filter_account_label(@filter)}
          class="min-w-0 truncate text-xs font-normal text-brand-500 dark:text-brand-300"
        >
          {scope}
        </span>
      </span>
      <button
        type="button"
        phx-click="drop-filter"
        phx-value-id={@filter.id}
        phx-target={@target}
        title={gettext("Remove")}
        aria-label={gettext("Remove %{pattern}", pattern: @filter.pattern)}
        class="flex h-4 w-4 flex-shrink-0 items-center justify-center rounded-full leading-none text-brand-500 transition hover:bg-brand-100 hover:text-brand-800 dark:text-brand-300 dark:hover:bg-brand-800 dark:hover:text-brand-100"
      >
        <span aria-hidden="true">×</span>
      </button>
    </span>
    """
  end

  # ── rows ──

  @doc false
  # The whole source list — vutuv and every server, with their accounts.
  #
  # Its own component because the card is offered in more than one density and
  # they must not drift: everything below the search field is this, rendered
  # once per variant with a different `prefix` (so no two rows share a DOM id)
  # and a different answer to "does a server start open".
  attr(:prefix, :string, required: true)
  attr(:target, :any, required: true)
  attr(:servers, :list, required: true)
  attr(:shown_servers, :list, required: true)
  attr(:hidden_servers, :integer, required: true)
  attr(:accounts, :list, required: true)
  attr(:account_count, :integer, required: true)
  attr(:vutuv_total, :integer, required: true)
  attr(:filter, :atom, required: true)
  attr(:sort, :atom, required: true)
  attr(:full, :any, required: true)
  attr(:twisted, :any, required: true)
  attr(:searching?, :boolean, required: true)
  attr(:more_accounts?, :boolean, required: true)
  attr(:anything_off?, :boolean, required: true)
  attr(:all_off?, :boolean, required: true)
  attr(:undo?, :boolean, required: true)

  defp sources_list(assigns) do
    ~H"""
      <%!-- One list, one level: vutuv is a server among the others.
      It used to sit under a "Fediverse" node that held everything else, which
      made the reader climb a level to reach an account and implied a
      difference the reader does not have — a post is from an account on a
      server, and which software that server runs is not their problem
      (Stefan, 2026-08-28). What the node also carried, "switch the whole
      fediverse off", is now one press of vutuv's own "only". --%>
      <div class="flex items-center gap-2 pb-1 text-xs">
        <button
          type="button"
          phx-click="all-servers"
          phx-target={@target}
          disabled={@filter == :all and not @anything_off?}
          class="font-semibold text-brand-600 disabled:text-slate-400 dark:text-brand-400 dark:disabled:text-slate-600"
        >
          {gettext("Select all")}
        </button>
        <span class="text-slate-300 dark:text-slate-600">|</span>
        <button
          type="button"
          phx-click="no-servers"
          phx-target={@target}
          disabled={@filter == :fediverse and @all_off?}
          class="font-semibold text-brand-600 disabled:text-slate-400 dark:text-brand-400 dark:disabled:text-slate-600"
        >
          {gettext("Clear all")}
        </button>
        <%!-- Offered only right after a bulk press, and worded as the act
        rather than as a state: "only this account" silences every other follow
        the member has, so the one thing they cannot do by hand afterwards is
        tell their own considered mutes from the ones this press just made. --%>
        <button
          :if={@undo?}
          type="button"
          phx-click="undo"
          phx-target={@target}
          class="ml-auto font-semibold text-slate-500 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
        >
          {gettext("Undo")}
        </button>
      </div>

      <.source_row
        prefix={@prefix}
        source="vutuv"
        label="vutuv"
        count={@vutuv_total}
        on?={@filter != :fediverse}
        partial?={@filter != :fediverse and Enum.any?(@accounts, & &1.muted?)}
        open?={@searching? or server_open?("vutuv", @twisted)}
        target={@target}
      />

      <%!-- What belongs to a source is drawn as belonging to it: an indent
      plus a hairline down the left, so the account rows read as one level below
      the row they hang under rather than as slightly-shifted siblings (Stefan,
      2026-08-28). The indent lives on the group, not on the rows, so a row
      carries no padding of its own and the two levels cannot drift apart.
      Measure it against the SOURCE ROW'S CHECKBOX, never against the row: a
      source row opens with a 16px twist button and an 8px gap, so `ml-2 pl-3`
      put the account box three pixels to the LEFT of the box it hangs under and
      read as a misalignment rather than as a level. `ml-6` drops the hairline
      from the source checkbox's left edge and `pl-6` lands the account checkbox
      under the source LABEL, which is the indent a tree is read by. --%>
      <div
        :if={@searching? or server_open?("vutuv", @twisted)}
        class="mb-2 ml-6 border-l border-slate-200 pl-6 dark:border-slate-700"
      >
        <%!-- The order as three words. A select is a 44px-tall control with
        its own chrome for a choice between three, sitting inside a list it is
        not part of; one line of text says the same and costs a third of it. --%>
        <div class="mb-1 flex flex-wrap items-center gap-x-3 text-xs">
          <button
            :for={{value, label} <- sort_options()}
            type="button"
            phx-click="sort"
            phx-value-sort={value}
            phx-target={@target}
            class={[
              "font-semibold",
              (to_string(@sort) == value && "text-slate-900 dark:text-slate-100") ||
                "text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            ]}
          >
            {label}
          </button>
        </div>

        <p :if={@accounts == []} class="py-1 text-xs text-slate-500 dark:text-slate-400">
          {gettext("No account found.")}
        </p>

        <.account_row :for={row <- @accounts} prefix={@prefix} row={row} target={@target} />

        <button
          :if={not @searching? and not @more_accounts?}
          type="button"
          phx-click="more-accounts"
          phx-target={@target}
          class="pt-1 text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          <%!-- It shows more of the list; it no longer searches, the field
          at the top of the card does that. So it says what it does and how
          long the list is, rather than sending the reader somewhere. --%>
          {gettext("More of your %{formatted} accounts", formatted: delimited_count(@account_count))}
        </button>
      </div>

      <div>
        <div>
          <%= for server <- @shown_servers do %>
            <.server_row
              prefix={@prefix}
              server={server}
              on?={@filter != :vutuv and not server.muted?}
              open?={@searching? or server_open?(server.host, @twisted)}
              target={@target}
            />
            <%!-- Capped like the vutuv branch and for the same reason: a
            member may follow six accounts on one server or three hundred, and
            the card cannot know which. Muted accounts are added past the cap
            there; here the whole server has its own switch one line up, so
            the cap is plain. --%>
            <div
              :if={@searching? or server_open?(server.host, @twisted)}
              class="mb-1 ml-6 border-l border-slate-200 pl-6 dark:border-slate-700"
            >
              <.account_row
                :for={account <- shown_accounts(server, @full, @searching?)}
                prefix={@prefix}
                row={account}
                target={@target}
              />
              <button
                :if={not @searching? and hidden_accounts(server, @full) > 0}
                type="button"
                phx-click="all-accounts"
                phx-value-host={server.host}
                phx-target={@target}
                class="pt-1 text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              >
                {ngettext(
                  "Show 1 more account",
                  "Show %{formatted} more accounts",
                  hidden_accounts(server, @full),
                  formatted: delimited_count(hidden_accounts(server, @full))
                )}
              </button>
            </div>
          <% end %>

          <button
            :if={@hidden_servers > 0}
            type="button"
            phx-click="more-servers"
            phx-target={@target}
            class="pt-1 text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("Show %{count} more servers", count: @hidden_servers)}
          </button>
        </div>
      </div>
    """
  end

  # One set, two readings. A card that shows every account at once and a card
  # that shows only its sources need opposite defaults, and the reader's twists
  # are the same act either way — so `twisted` records what they touched and the
  # variant decides what untouched means.
  # The three orders, named once: the select renders them as options and the
  # compact row as words, and a fourth order must not have to be added twice.
  defp sort_options do
    [
      {"active", gettext("Busiest first")},
      {"recent", gettext("Posted last")},
      {"name", gettext("A–Z")}
    ]
  end

  # A source starts folded and opens when the reader asks. The card lists
  # fifteen servers and hundreds of accounts; opening all of it at once made it
  # 1054px tall in a 971px window, so the search field scrolled out of sight
  # while the reader was still looking for a row (Stefan, 2026-08-28).
  defp server_open?(host, twisted), do: host in twisted

  attr(:prefix, :string, required: true)
  attr(:source, :string, required: true)
  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:on?, :boolean, required: true)
  attr(:partial?, :boolean, default: false)
  attr(:open?, :boolean, required: true)
  attr(:target, :any, required: true)

  defp source_row(assigns) do
    ~H"""
    <div class="row-reveal-host flex items-center gap-2 py-1">
      <.twist id={@source} open?={@open?} target={@target} />
      <%!-- `data-filter-tab` is what the press paint keys on (assets/css/app.css):
      switching a source reloads the timeline exactly as a tab press used to, so
      it wears the same marker and the list dims while the answer is on its
      way — otherwise the control says nothing at all on a slow line. --%>
      <input
        type="checkbox"
        id={"#{@prefix}-source-#{@source}"}
        data-filter-tab={@source}
        checked={@on?}
        phx-click="toggle-source"
        phx-value-source={@source}
        phx-target={@target}
        data-partial={@partial? && "1"}
        class="h-4 w-4 shrink-0 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600"
      />
      <label
        for={"#{@prefix}-source-#{@source}"}
        class="min-w-0 shrink truncate text-sm font-semibold text-slate-900 dark:text-slate-100"
      >
        {@label}
      </label>
      <.only_button host={@source} label={@label} target={@target} />
      <span class="ml-auto shrink-0 text-xs tabular-nums text-slate-500 dark:text-slate-400">
        {compact_count(@count)}
      </span>
    </div>
    """
  end

  @doc false
  # Kayak's "only", on every source row: switch this one on and the rest off.
  #
  # It exists because the common wish is not "mute this one" but "just this one
  # for now", and doing that by hand is one press per source. It writes the same
  # two columns the checkboxes write, so it is a shortcut and not a second
  # mechanism — and "Select all" is the way back.
  #
  # It sits on a source row and on an account row, and the two cost very
  # different things. A source's "off" is one entry in a short array on the
  # member's own row; an account's "off" is a row per follow, so the account
  # variant is the one control in this card that writes over a considered
  # choice — the handful of people somebody silenced by hand become
  # indistinguishable from the thousands this press silenced. That is why every
  # bulk act here captures the state it is about to overwrite and offers an
  # undo (`remember/1`), and why "Select all" had to learn to unmute accounts
  # as well: without it there is no way back from an account's "only" short of
  # one press per follow.
  #
  # It sits directly after the name rather than past the count at the far edge,
  # and on a pointer device it only appears while the row is under the cursor
  # (`.row-reveal`, components.css). Twenty rows each ending in the same word
  # read as a column of "Only", which is a lot of ink for a shortcut; beside the
  # name it is where the reader is already looking, and it is quiet until they
  # are looking at that row. On touch there is no hover to reveal it with, so it
  # simply stands there — the phone reaches this card through the filter sheet,
  # which is full width and has more room for it than the desktop rail does.
  #
  # The padding is pulled back out with a negative margin, so a finger-sized
  # target does not make every row taller on the desktop.
  attr(:host, :string, default: nil)
  attr(:key, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:target, :any, required: true)

  defp only_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="only"
      phx-value-host={@host}
      phx-value-key={@key}
      phx-target={@target}
      title={gettext("Show only %{source}", source: @label)}
      class="row-reveal -my-1.5 shrink-0 rounded px-1.5 py-1.5 text-xs font-semibold text-slate-400 hover:text-brand-700 dark:text-slate-500 dark:hover:text-brand-300"
    >
      {gettext("Only")}
    </button>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:server, :map, required: true)
  # Off is two things: this host muted, or — for a member whose row still holds
  # the retired `feed_source = "vutuv"` — the whole fediverse switched off by a
  # control this card no longer has. Reading only `muted?` would tick every
  # server over a feed that carries none of them; the next write here normalises
  # the state away (see `set_sources/3`).
  attr(:on?, :boolean, required: true)
  attr(:open?, :boolean, required: true)
  attr(:target, :any, required: true)

  defp server_row(assigns) do
    ~H"""
    <div class="row-reveal-host flex items-center gap-2 py-1">
      <.twist id={@server.host} open?={@open?} target={@target} />
      <input
        type="checkbox"
        id={"#{@prefix}-host-#{@server.host}"}
        checked={@on?}
        phx-click="toggle-host"
        phx-value-host={@server.host}
        phx-target={@target}
        class="h-4 w-4 shrink-0 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600"
      />
      <span aria-hidden="true" class="shrink-0 text-xs opacity-70">🌐</span>
      <label
        for={"#{@prefix}-host-#{@server.host}"}
        class="min-w-0 shrink truncate text-sm text-slate-700 dark:text-slate-300"
      >
        {@server.host}
      </label>
      <.only_button host={@server.host} label={@server.host} target={@target} />
      <span class="ml-auto shrink-0 text-xs tabular-nums text-slate-500 dark:text-slate-400">
        {compact_count(@server.posts)}
      </span>
    </div>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:row, :map, required: true)
  attr(:target, :any, required: true)

  defp account_row(assigns) do
    ~H"""
    <div class="row-reveal-host flex items-center gap-2 py-1">
      <%!-- The checkbox carries its own name and its own touch target. It used
      to be labelled by the row's text, which cost nothing until that text
      became a link to the account: a link inside a `<label for>` both navigates
      and toggles, so one of the two acts always surprises. The wrapping label
      is what keeps the target finger-sized without swallowing the link. --%>
      <label class="-m-1.5 flex shrink-0 cursor-pointer items-center p-1.5">
        <input
          type="checkbox"
          id={"#{@prefix}-account-#{@row.key}"}
          checked={not @row.muted?}
          phx-click="toggle-account"
          phx-value-key={@row.key}
          phx-target={@target}
          aria-label={gettext("Show posts by %{name}", name: @row.name)}
          class="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600"
        />
      </label>
      <%!-- A row names somebody, so it goes to them. Deliberately not bold: six
      of these under a heading read as six headings, and the weight was never a
      decision — it came from `components.css`'s element-level `label` rule,
      which this markup inherited by accident. --%>
      <.link
        href={@row.path}
        class="min-w-0 shrink truncate text-sm font-normal text-slate-700 hover:text-brand-700 dark:text-slate-300 dark:hover:text-brand-300"
      >
        {@row.name}
        <span :if={@row.handle} class="text-xs text-slate-500 dark:text-slate-400">
          {@row.handle}
        </span>
      </.link>
      <.only_button key={@row.key} label={@row.name} target={@target} />
      <span class="ml-auto shrink-0 text-xs tabular-nums text-slate-500 dark:text-slate-400">
        {compact_count(@row.posts)}
      </span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:open?, :boolean, required: true)
  attr(:target, :any, required: true)

  defp twist(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="twist"
      phx-value-key={@id}
      phx-target={@target}
      aria-expanded={to_string(@open?)}
      aria-label={gettext("Expand or collapse")}
      class="h-5 w-4 shrink-0 rounded text-xs leading-none text-slate-500 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"
    >
      {(@open? && "▾") || "▸"}
    </button>
    """
  end

  # ── events ──

  @impl true
  def handle_event("twist", %{"key" => key}, socket) do
    twisted = socket.assigns.twisted

    {:noreply,
     assign(
       socket,
       :twisted,
       (MapSet.member?(twisted, key) && MapSet.delete(twisted, key)) || MapSet.put(twisted, key)
     )}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    {:noreply, socket |> assign(:sort, sort_atom(sort)) |> force_load()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> force_load()}
  end

  def handle_event("more-accounts", _params, socket) do
    {:noreply, socket |> assign(:more_accounts?, true) |> force_load()}
  end

  def handle_event("more-servers", _params, socket) do
    {:noreply, socket |> assign(:more_servers?, true) |> force_load()}
  end

  def handle_event("all-accounts", %{"host" => host}, socket) do
    {:noreply, assign(socket, :full, MapSet.put(socket.assigns.full, host))}
  end

  # The two source rows are the old tabs: they write the same column, so
  # switching one off here is exactly what pressing the other tab used to do —
  # and the last one standing cannot be switched off, or the feed would be a
  # blank page with no way back to itself.
  def handle_event("toggle-source", %{"source" => source}, socket) do
    filter = socket.assigns.filter

    next =
      case {source, filter} do
        {"vutuv", :fediverse} -> :all
        {"vutuv", _both_or_vutuv} -> :fediverse
        {"fediverse", :vutuv} -> :all
        {"fediverse", _both_or_fediverse} -> :vutuv
      end

    :ok = Posts.remember_feed_filter(socket.assigns.current_user, next, filter)

    {:noreply, changed(socket)}
  end

  def handle_event("toggle-host", %{"host" => host}, socket) do
    user = socket.assigns.current_user
    muted? = host in Fediverse.muted_hosts(user)
    {:ok, _hosts} = Fediverse.set_host_mute(user, host, not muted?)

    {:noreply, changed(socket)}
  end

  # The two bulk controls now cover the whole list, vutuv included: with the
  # "Fediverse" node gone there is no half left for them to mean.
  def handle_event("all-servers", _params, socket) do
    socket = remember(socket)
    user = socket.assigns.current_user

    # It clears the account mutes too, which it did not have to before an
    # account could be muted in bulk: "only this account" leaves thousands of
    # them set, and this is the standing way back from that. The cost is that a
    # deliberate mute goes with them, which is what the undo beside it answers.
    :ok = Social.restore_follow_mutes(user, [])
    :ok = Fediverse.restore_remote_follow_mutes(user, [])

    {:noreply, set_sources(socket, :all, [])}
  end

  # Deliberately leaves the account mutes alone: every host muted and vutuv off
  # already delivers nothing, so there is no second switch to throw and nothing
  # of the member's to overwrite.
  def handle_event("no-servers", _params, socket) do
    {:noreply, socket |> remember() |> set_sources(:fediverse, every_host(socket))}
  end

  # Kayak's "only": this source on, the rest off. vutuv and a server are the
  # same act, told apart by which of the two columns carries the "off".
  def handle_event("only", %{"host" => "vutuv"}, socket) do
    {:noreply, socket |> remember() |> set_sources(:all, every_host(socket))}
  end

  def handle_event("only", %{"host" => host}, socket) do
    {:noreply, socket |> remember() |> set_sources(:fediverse, every_host(socket) -- [host])}
  end

  # The same act one level down. Which sources go off is the same question; what
  # is new is the second half, the accounts *inside* the surviving source.
  def handle_event("only", %{"key" => key}, socket) do
    case find_row(socket, key) do
      nil -> {:noreply, socket}
      row -> {:noreply, socket |> remember() |> only_account(row)}
    end
  end

  # Back to exactly the state the last bulk press overwrote — all four things it
  # could have touched, because a partial restore is worse than none: it would
  # leave the member with a state they never chose and no name for it.
  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      nil ->
        {:noreply, socket}

      undo ->
        user = socket.assigns.current_user
        :ok = Social.restore_follow_mutes(user, undo.follows)
        :ok = Fediverse.restore_remote_follow_mutes(user, undo.remotes)

        {:noreply, socket |> assign(:undo, nil) |> set_sources(undo.filter, undo.hosts)}
    end
  end

  def handle_event("word-draft", params, socket) do
    {draft, account} = draft_params(params)

    {:noreply,
     socket
     |> assign(word_draft: draft, word_account: account)
     |> assign(:preview, preview(socket, draft, account))}
  end

  def handle_event("tag-draft", params, socket) do
    {draft, account} = draft_params(params)

    {:noreply, assign(socket, tag_draft: draft, tag_account: account)}
  end

  def handle_event("add-word", params, socket) do
    {:noreply,
     socket
     |> add_filter(:keyword, params)
     |> assign(word_draft: "", word_account: "", preview: nil)}
  end

  def handle_event("add-tag", params, socket) do
    {:noreply, socket |> add_filter(:tag, params) |> assign(tag_draft: "", tag_account: "")}
  end

  # A suggestion straight off the page is about the tag, not about who used it:
  # it is one press, and there is nowhere in it to say "only from these" — so
  # its params carry no account and the rule reads everyone.
  def handle_event("hide-tag", %{"pattern" => pattern}, socket) do
    {:noreply, add_filter(socket, :tag, %{"pattern" => pattern})}
  end

  def handle_event("drop-filter", %{"id" => id}, socket) do
    ContentFilters.delete_filter(socket.assigns.current_user, id)

    {:noreply, changed(socket)}
  end

  def handle_event("toggle-account", %{"key" => key}, socket) do
    user = socket.assigns.current_user
    row = find_row(socket, key)

    mute_account(user, key, row && not row.muted?)

    # One considered switch ends the offer: an undo that survived it would put
    # this tick back too, under a label that only mentions the bulk press.
    {:noreply, socket |> assign(:undo, nil) |> changed()}
  end

  # ── plumbing ──

  # Every switch lands in a context, never in an assign here: the feed reads
  # those tables for its own query, so the band's job is to write and then hand
  # the fresh member back up so the timeline is re-run against it.
  defp changed(socket) do
    user = reload_user(socket)
    send(self(), {:filter_band, :changed, user})

    socket |> assign(:current_user, user) |> force_load()
  end

  # The band's own acts bypass the `load/1` gate: what they wrote lands in
  # `follows` / `fediverse_follows` / content filters, so no assign this
  # component is handed has to differ for the answer to have changed.
  defp force_load(%{assigns: %{block: :sources}} = socket), do: load_sources(socket)
  defp force_load(socket), do: load(socket)

  defp reload_user(socket), do: Repo.get!(Vutuv.Accounts.User, socket.assigns.current_user.id)

  # Both halves of the rule off one form. The account is optional and often
  # absent — a `hide-tag` press sends no such field at all — so it defaults to
  # blank, which the changeset reads as "every account".
  defp draft_params(params),
    do: {Map.get(params, "pattern", ""), Map.get(params, "account", "")}

  # A blank line is not a rule, and the cap is the context's to enforce — the
  # band only has to stay quiet when either says no. The form's own params go
  # through, so the account rides along wherever the form had a field for it and
  # is simply absent where it did not.
  defp add_filter(socket, kind, params) do
    {pattern, account} = draft_params(params)

    case String.trim(pattern) do
      "" ->
        socket

      trimmed ->
        ContentFilters.create_filter(socket.assigns.current_user, %{
          "kind" => kind,
          "pattern" => trimmed,
          "account" => account,
          # Substring, not whole words. German is the reason and it is not a
          # detail: a member typing "Zeugnis" means "Arbeitszeugnis" and
          # "Zeugnisanalyse" too, and "Bitcoin" is expected to cover "Bitcoins"
          # — a whole-word rule silently catches none of those. The card used to
          # answer that with a `*` grammar nobody outside this file could be
          # expected to know (Stefan, 2026-08-28). The live preview below is
          # what makes the permissive default safe: a rule that is too wide
          # names its victims before it is saved. Anyone who really wants the
          # bare word has the "whole words" checkbox on /settings/filters.
          "whole_word" => false
        })

        changed(socket)
    end
  end

  # What the rule being typed would do to the feed the reader is looking at.
  # Built from the real matcher (`PostTeaser.filtered_pattern/3`, the one thing
  # that knows how to ask a vutuv post and a cached remote one the same
  # question), so the preview cannot drift from what actually gets folded.
  defp preview(socket),
    do: preview(socket, socket.assigns[:word_draft] || "", socket.assigns[:word_account] || "")

  # What the rule being typed would do to the feed in front of the reader: how
  # many posts, and which ones. The count alone answered "is this rule too
  # wide?" and left "is it the right rule?" open — a member typing `Zeugnis`
  # cannot tell from a `3` whether those three are the ones they meant.
  #
  # Quoted per **post**, not per row. A row is a conversation and the match is
  # regularly an ancestor rather than the post the row is keyed on, so quoting
  # the row would name the wrong author and the wrong sentence.
  defp preview(socket, draft, account) do
    pattern = String.trim(to_string(draft))

    if pattern == "" do
      nil
    else
      hits = matching_posts(socket, ContentFilters.compile_draft(pattern, account))

      %{count: length(hits), quotes: hits |> Enum.take(@preview_quotes) |> Enum.map(&quote_of/1)}
    end
  end

  # Every post on the page the rule would catch. The reader's own posts are left
  # out, exactly as the filter itself leaves them out — a preview that promised
  # to fold something the feed then keeps would be worse than no preview.
  defp matching_posts(socket, compiled) do
    viewer_id = socket.assigns.current_user.id

    socket.assigns
    |> Map.get(:entries, [])
    |> Enum.flat_map(&preview_records/1)
    |> Enum.reject(&(Map.get(&1, :user_id) == viewer_id))
    |> Enum.filter(&(ContentFilters.filtered(&1, compiled) != nil))
  end

  defp preview_records(entry) do
    if Posts.remote_feed_entry?(entry),
      do: [PostTeaser.record(entry)],
      else: Posts.thread_posts(entry)
  end

  defp quote_of(record),
    do: record |> PostTeaser.author_of() |> Map.put(:text, PostTeaser.plain_line(record))

  # The tags actually in front of the reader, most frequent first — a suggestion
  # list drawn from the feed answers "what is flooding me" without them having
  # to remember how a tag is spelled. Already-muted ones are dropped: their chip
  # is above, and offering to mute them twice would just fail the unique index.
  defp tag_suggestions(socket, filters) do
    FeedBand.tags_on_page(socket.assigns[:entries] || [],
      except: Enum.map(filters, & &1.pattern)
    )
  end

  defp mute_account(user, "user:" <> id, muted?) when is_boolean(muted?) do
    Social.set_follow_mute(user, %Vutuv.Accounts.User{id: id}, muted?)
  end

  defp mute_account(user, "page:" <> id, muted?) when is_boolean(muted?) do
    Social.set_follow_mute(user, %Vutuv.Organizations.Organization{id: id}, muted?)
  end

  defp mute_account(user, "remote:" <> id, muted?) when is_boolean(muted?) do
    Fediverse.set_remote_follow_mute(user, id, muted?)
  end

  defp mute_account(_user, _key, _missing), do: :ok

  defp find_row(socket, key) do
    Enum.find(socket.assigns.accounts, &(&1.key == key)) ||
      socket.assigns.servers
      |> Enum.flat_map(& &1.accounts)
      |> Enum.find(&(&1.key == key))
  end

  # One write for both columns, so a bulk act can never land half-applied — and
  # the vutuv half is stored as `users.feed_source`, the fediverse half as
  # `users.feed_muted_hosts`, which is why "everything off" needs both.
  #
  # `:vutuv` is deliberately never written any more. It used to mean "the whole
  # fediverse off", which was a single control this card no longer has; the same
  # state is now every host muted, so the per-server checkboxes describe it
  # truthfully instead of all reading "on" over a feed that carries none of them.
  defp set_sources(socket, filter, muted_hosts) do
    user = socket.assigns.current_user
    :ok = Posts.remember_feed_filter(user, filter, socket.assigns.filter)
    {:ok, _hosts} = Fediverse.set_muted_hosts(user, muted_hosts)

    changed(socket)
  end

  defp every_host(socket), do: socket.assigns.hosts

  # What the next bulk press is about to overwrite, captured before it runs.
  # The muted sets and not the whole ones: a member follows thousands of people
  # and silences a handful, so this is the small half and the only half a
  # restore needs.
  defp remember(socket) do
    user = socket.assigns.current_user

    assign(socket, :undo, %{
      filter: socket.assigns.filter,
      hosts: Fediverse.muted_hosts(user),
      follows: Social.muted_follow_ids(user),
      remotes: Fediverse.muted_remote_follow_ids(user)
    })
  end

  # "Only this account" is two halves. Which *sources* stay on is the same
  # question the source-level button answers; what is new is the accounts inside
  # the one that survives.
  #
  # For a remote account the mute is scoped to its own server, because the other
  # servers are switched off a whole host at a time. Muting their accounts as
  # well would outlive that: the reader ticks such a server back on and it
  # delivers nothing, with no row in the card admitting why.
  defp only_account(socket, %{kind: :remote, id: id, host: host}) do
    :ok = Fediverse.mute_remote_follows_except(socket.assigns.current_user, host, id)

    set_sources(socket, :fediverse, every_host(socket) -- [host])
  end

  defp only_account(socket, %{kind: kind, id: id}) do
    :ok = Social.mute_follows_except(socket.assigns.current_user, followee(kind, id))

    set_sources(socket, :all, every_host(socket))
  end

  defp followee(:page, id), do: %Vutuv.Organizations.Organization{id: id}
  defp followee(_user, id), do: %Vutuv.Accounts.User{id: id}

  defp shown_servers(servers, true), do: servers

  defp shown_servers(servers, false) do
    # A switched-off server stays listed wherever it sits in the order, so a
    # silent server is not also an invisible one — bounded, because "only this
    # account" switches every one of them off at once and the card would then
    # be one long list of empty checkboxes. Past the bound the rest are one
    # press away, on the "show more servers" line this same cap draws.
    shown = Enum.take(servers, @top_servers)
    muted = servers |> Enum.drop(@top_servers) |> Enum.filter(& &1.muted?)

    shown ++ Enum.take(muted, @top_servers)
  end

  # A server's accounts, capped unless the reader asked for the rest. A muted
  # account is added past the cap, exactly as the vutuv branch does it: the band
  # is the only place to switch one back on, so it can never fall off the list.
  defp shown_accounts(server, full, searching? \\ false) do
    if searching? or server.host in full do
      server.accounts
    else
      shown = Enum.take(server.accounts, @top_server_accounts)

      muted =
        server.accounts |> Enum.drop(@top_server_accounts) |> Enum.filter(& &1.muted?)

      shown ++ Enum.take(muted, @top_server_accounts)
    end
  end

  defp hidden_accounts(server, full),
    do: length(server.accounts) - length(shown_accounts(server, full))

  defp sort_atom("recent"), do: :recent
  defp sort_atom("name"), do: :name
  defp sort_atom(_active), do: :active
end
