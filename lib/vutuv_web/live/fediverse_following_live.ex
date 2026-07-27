defmodule VutuvWeb.FediverseFollowingLive do
  @moduledoc """
  The accounts the member follows on other networks (`/settings/fediverse/following`,
  issue #1160) — the mirror image of `VutuvWeb.FediverseFollowersLive`, and the
  one place a follow is started, watched and taken back.

  The page leads with the **add-by-address box**, because that is what somebody
  opens it to do; the table below is the same searched, filtered, sorted, paged
  table the follower browser uses (`VutuvWeb.BrowseTable`), with two columns of
  its own: what state the follow is in and how to end it.

  Two deliberate choices about honesty:

    * a follow that has not been answered reads **"Requested"**, not
      "Following". An account that approves its followers by hand may take days
      or never answer, and showing it as settled would be a lie the member acts
      on.
    * a member who does not federate gets the **explanation and the switch**
      rather than a redirect. The Follow is signed with their own actor key, so
      there is genuinely nothing to do here first — but "why can I not?" with
      the answer next to it beats being bounced to another page. And which
      explanation matters: `Fediverse.federated?/1` is equally false for
      somebody who never opted in and for somebody the moderation freezer is
      holding, and telling the second to flip a switch they already flipped is
      the worst place to be vague.
    * the row wording follows the state. A `requested` row is not something you
      "unfollow" and it has no "following since" date, so the control reads
      "Cancel request" and the column is neutral.

  Owner-only by construction: it lives in the `/settings` scope and reads only
  `current_user`'s rows.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.BrowseTable
  import VutuvWeb.FediverseComponents

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Handles
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Accounts you follow elsewhere"))
     |> assign(:user, user)
     |> assign(:federating?, Fediverse.federated?(user))
     |> assign(:blocked_reason, Fediverse.follow_refusal(user))
     |> assign(:address, "")
     |> assign(:error, nil)
     |> assign(:local_member, nil)
     |> assign_totals()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filters, Fediverse.browse_filters(params))
     |> prefill(params["address"])
     |> load_page(params)}
  end

  # `?address=` arrives from the search page (issue #1160), which offers a full
  # `@name@server` query as something to follow. Prefilled rather than followed
  # on arrival: a GET must not send a signed request to a stranger's server,
  # and the member should see what they are about to do.
  defp prefill(socket, address) when is_binary(address), do: assign(socket, :address, address)
  defp prefill(socket, _address), do: socket

  # What the whole list looks like, whatever is filtered out of the view of it:
  # the headline count and the server dropdown. Deliberately not in the page
  # loader — neither depends on the filters, the sort or the page, so recomputing
  # them per keystroke would be two extra queries for an unchanged answer. Only
  # a follow or an unfollow can move them, so only those refresh.
  defp assign_totals(socket) do
    user = socket.assigns.user

    socket
    |> assign(:total_follows, Fediverse.remote_follow_count(user))
    |> assign(:hosts, Fediverse.remote_follow_hosts(user))
  end

  defp load_page(socket, params \\ %{}) do
    user = socket.assigns.user
    filters = socket.assigns.filters
    per_page = Fediverse.browse_per_page()
    total = Fediverse.count_remote_follows(user, filters)
    page = Pages.effective_page(params, total, per_page)

    follows =
      Fediverse.list_remote_follows_page(user, filters, %{"page" => page},
        total: total,
        per_page: per_page
      )

    socket
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:follows, follows)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("follow", %{"address" => address}, socket) do
    case Fediverse.follow_remote(socket.assigns.user, address) do
      {:ok, follow} ->
        # Patch rather than reload in place: it keeps any active filter and
        # drops the `?address=` the search page may have arrived with, so a
        # later sort does not put the followed address back in the box.
        {:noreply,
         socket
         |> assign(:address, "")
         |> assign_error(nil)
         |> assign_totals()
         |> put_flash(:info, follow_sent_message(follow))
         |> patch(%{})}

      {:error, reason} ->
        {:noreply, socket |> assign(:address, address) |> assign_error(reason, address)}
    end
  end

  # Typing again clears the last refusal, so the box is not still shouting about
  # an address the member has since corrected.
  def handle_event("typing", %{"address" => address}, socket) do
    {:noreply, socket |> assign(:address, address) |> assign_error(nil)}
  end

  def handle_event("unfollow", %{"id" => id}, socket) do
    case Fediverse.unfollow_remote(socket.assigns.user, id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Unfollowed."))
         |> assign_totals()
         |> load_page()}

      {:error, :not_found} ->
        {:noreply, load_page(socket)}
    end
  end

  # Replaced, not pushed: the search box is debounced but still fires per burst
  # of typing, and on a phone the back gesture is the way out of a page. Pushing
  # would make leaving take one press per search term.
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{"q" => params["q"], "server" => params["server"]}, replace: true)}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    {:noreply, patch(socket, %{"sort" => col, "dir" => next_dir(socket.assigns.filters, col)})}
  end

  def handle_event("filter_server", %{"host" => host}, socket) do
    {:noreply, patch(socket, %{"server" => host})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/fediverse/following")}
  end

  defp patch(socket, overrides, opts \\ []) do
    query = build_query(socket.assigns.filters, overrides)
    push_patch(socket, [to: ~p"/settings/fediverse/following?#{query}"] ++ opts)
  end

  # The refusal, plus the one thing a refusal sometimes needs beyond a sentence:
  # the member of this very vutuv the address turned out to name. Resolved here
  # rather than in the template, so the lookup happens once when the answer
  # arrives instead of on every later re-render while the message stands.
  defp assign_error(socket, reason, address \\ nil)

  defp assign_error(socket, :local_account, address),
    do: socket |> assign(:error, :local_account) |> assign(:local_member, local_member(address))

  defp assign_error(socket, reason, _address),
    do: socket |> assign(:error, reason) |> assign(:local_member, nil)

  defp local_member(address) do
    with {:ok, {name, _host}} <- RemoteFollow.parse_address(address),
         %{username: username} <- Accounts.get_user_by_username(Handles.normalize(name)) do
      username
    else
      _ -> nil
    end
  end

  # ── Wording ───────────────────────────────────────────────────────────────

  # A Follow is a request, so the confirmation says what really happened rather
  # than "Following" — and names the account, since the row it just added may be
  # on page four of a filtered table.
  defp follow_sent_message(%Follow{remote_account: %RemoteAccount{} = account}) do
    gettext("Follow request sent to %{account}.", account: RemoteAccount.label(account))
  end

  # The confirmation that goes with `end_follow_label/1`. This page knows the
  # account behind the row (the table preloads it), so it names it.
  defp end_follow_confirm(follow) do
    account = RemoteAccount.label(follow.remote_account)

    if Follow.accepted?(follow),
      do: gettext("Stop following %{account}?", account: account),
      else: gettext("Withdraw your follow request to %{account}?", account: account)
  end

  # Both middle columns fold away on a phone (`phone_hidden_class/0`), so the
  # two facts a reader came for - who, and what state the follow is in - keep
  # the width.
  # "Added", not the follower table's "Following since": half the rows here are
  # requests nobody has answered, and on those the date is when you asked, not
  # when you started following. A header the badge two columns over contradicts
  # is worse than a duller word.
  defp columns do
    [
      {"account", gettext("Account"), nil},
      {"server", gettext("Server"), phone_hidden_class()},
      {"followed", gettext("Added"), phone_hidden_class()}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell
      user={@user}
      active={:fediverse}
      title={gettext("Accounts you follow elsewhere")}
      crumbs={[
        {gettext("Settings"), ~p"/settings"},
        {gettext("Fediverse"), ~p"/settings/fediverse"},
        # Not the bare "Following": that word is already the *state* of a vutuv
        # follow button ("Folge ich" in German), so as a breadcrumb it reads as
        # a status rather than a place. A noun names the page.
        gettext("Accounts followed")
      ]}
    >
      <div class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <.section_title>{gettext("Accounts you follow elsewhere")}</.section_title>
            <span
              :if={@federating?}
              id="following-total"
              class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300"
            >
              {delimited_count(@total_follows)}
            </span>
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Mastodon and the other networks work like email: an address is enough. Paste one here and vutuv asks that server to let you follow the account."
            )}
          </p>

          <%= if @federating? do %>
            <%!-- The add box is the reason this page exists, so it sits above
                  everything else and is a full-size input at every width. --%>
            <.address_form
              id="follow"
              address={@address}
              error={@error}
              event="follow"
              submit={gettext("Follow")}
              class="mt-4"
            >
              <:error_detail>
                <%!-- The profile when the handle really resolves to a member,
                      the search when it does not (a pasted profile URL that is
                      local but names nothing) — either way a next step, never a
                      sentence that just stops. --%>
                <.link
                  :if={@error == :local_account and @local_member}
                  navigate={~p"/#{@local_member}"}
                  id="local-member-link"
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-300"
                >
                  {gettext("Open their profile")} ›
                </.link>
                <.link
                  :if={@error == :local_account and is_nil(@local_member)}
                  navigate={~p"/search?#{[q: @address]}"}
                  id="local-member-search"
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-300"
                >
                  {gettext("Search for them here")} ›
                </.link>
              </:error_detail>
            </.address_form>
          <% else %>
            <.follow_refusal_panel
              id="not-federating"
              reason={@blocked_reason}
              address={@address}
              class="mt-4"
            />
          <% end %>

          <%= if @federating? and @total_follows == 0 do %>
            <%!-- Says what actually happens now that #1161 has shipped the
                  timeline half. It said "the next thing we are building" while
                  the feed source did not exist yet; leaving that in would be a
                  false sentence on the very page where the follow is made. --%>
            <p class="mt-4 text-sm text-slate-600 dark:text-slate-400" id="no-following">
              {gettext(
                "You do not follow anybody out there yet. Once you do, what they post appears in your feed among everything else."
              )}
            </p>
          <% end %>

          <%= if @federating? and @total_follows > 0 do %>
            <.filter_form id="following-filter" filters={@filters} hosts={@hosts} class="mt-6" />

            <p
              :if={@follows == []}
              class="mt-4 text-sm text-slate-600 dark:text-slate-400"
              id="no-matches"
            >
              {gettext("Nothing matches that. Try a shorter search, or clear the filters.")}
            </p>

            <div :if={@follows != []} class="card__tablewrap mt-4">
              <table class="pure-table">
                <thead>
                  <tr>
                    <.sort_header
                      :for={{col, label, class} <- columns()}
                      col={col}
                      label={label}
                      class={class}
                      filters={@filters}
                    />
                    <th>{gettext("State")}</th>
                  </tr>
                </thead>
                <tbody id="following">
                  <tr :for={follow <- @follows} id={"follow-#{follow.id}"}>
                    <td>
                      <.account_link
                        uri={follow.remote_account.actor_uri}
                        name={follow.remote_account.name}
                        handle={RemoteAccount.display_handle(follow.remote_account)}
                      />
                    </td>
                    <td class={phone_hidden_class()}>
                      <.server_filter
                        host={follow.remote_account.host}
                        title={gettext("Show only accounts on this server")}
                      />
                    </td>
                    <td class={[phone_hidden_class(), "whitespace-nowrap text-slate-600 dark:text-slate-400"]}>
                      <.local_time
                        at={follow.inserted_at}
                        id={"followed-#{follow.id}"}
                        format="%Y-%m-%d"
                      />
                    </td>
                    <td>
                      <div class="flex flex-wrap items-center justify-end gap-x-3 gap-y-1">
                        <span
                          data-follow-state={follow.state}
                          class={[
                            "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ring-1",
                            follow_state_class(follow)
                          ]}
                        >
                          {follow_state_label(follow)}
                        </span>
                        <button
                          type="button"
                          phx-click="unfollow"
                          phx-value-id={follow.id}
                          id={"unfollow-#{follow.id}"}
                          data-confirm={end_follow_confirm(follow)}
                          class="inline-flex min-h-10 items-center px-2 text-sm font-semibold text-rose-600 hover:text-rose-800 dark:text-rose-400 dark:hover:text-rose-300"
                        >
                          {end_follow_label(follow)}
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.browse_footer
              :if={@follows != []}
              page={@page}
              per_page={@per_page}
              total={@total}
              path={~p"/settings/fediverse/following"}
              filters={@filters}
            />
          <% end %>
        </.card>

        <.card>
          <.section_title>{gettext("What following out there means")}</.section_title>
          <div class="mt-2 space-y-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            <p>
              {gettext(
                "The other server decides. Most accounts accept straight away; one that checks its followers by hand stays on \"Requested\" until somebody there says yes."
              )}
            </p>
            <p>
              {gettext(
                "Who you follow is yours alone. Your profile publishes how many accounts you follow out there, never which ones."
              )}
            </p>
            <%!-- The same promise the replies switch makes on the Fediverse
                  page (issue #1069), for the same reason: this is where the
                  member decides, so this is where they have to be told what
                  gets stored. Leaving it to the privacy page means an
                  installation whose operator never edits it says nothing at
                  all. --%>
            <p>
              {gettext(
                "To show their posts we keep a copy here for up to six months. If the author deletes or edits something, ours follows; and when you stop following an account, its posts are deleted here at once."
              )}
            </p>
          </div>
          <.card_footer_link href={~p"/settings/fediverse"}>
            {gettext("Back to Fediverse settings")}
          </.card_footer_link>
        </.card>
      </div>
    </.settings_shell>
    """
  end
end
