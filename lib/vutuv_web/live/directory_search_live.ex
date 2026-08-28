defmodule VutuvWeb.DirectorySearchLive do
  @moduledoc """
  The member directory's search box, embedded into `/system/members` via
  `live_render` from `VutuvWeb.DirectoryController` (the profile / feed /
  job-board pattern) so the controller keeps owning the agent-format siblings
  `/system/members.md` and friends.

  It is a **field** search, not the free-text page at `/search`: a plain
  case-insensitive substring in first name, last name and username, OR-ed
  across whichever of the three the member leaves ticked
  (`Vutuv.Directory.search/3`). The rows are the directory's own
  (`UserHTML.card_list` with `filed_names`), so a result reads exactly like the
  letter page it would otherwise have been found on, `rel="nofollow"` on an
  opted-out member's row included.

  **At least one box is always ticked, and unticking the last one ticks all
  three** — the fallback `Directory.parse_search_fields/1` applies, unchanged,
  on every path. One rule rather than two, and the reason is a rendering fact
  worth knowing: keeping the previous selection instead (the obvious "refuse
  the click") leaves `@fields` unchanged, so the diff carries nothing for that
  checkbox, morphdom never touches it, and the box stays visibly unticked while
  the server searches as though it were on. A refusal the page cannot show is
  not a refusal. Resetting to all three changes `@fields`, so all three boxes
  tick themselves again in the same patch and the count moves with them.

  **A large result set is revealed in bites, not paged.** The count is stated
  first (that is the answer to "did I spell it right"), then
  `Directory.results_step/0` rows, then a control for the next bite up to
  `results_ceiling/0`, past which the box asks for another letter instead — a
  pager under a search-as-you-type field is a trap, since the next keystroke
  invalidates whichever page you walked to.

  Because it is off-router it cannot `push_patch`, so the box is a real **GET
  form** at `/system/members`: keystrokes patch the results over the socket
  (`phx-change`, debounced), while Enter submits the form and lands on a
  shareable `?q=` URL whose dead render shows the same results. That is also
  the no-JS path, which is why "show more" renders as a `?show=` link until
  the socket connects and why a follow pressed on a result row (a classic CSRF
  POST back to the referrer) comes back to the search it was pressed in.

  The `?q=` page is `noindex` (the controller stamps it): search results are
  the hall of mirrors `/search` is noindexed for, and here they would be a
  second one carrying members who asked to stay out of search engines.
  """

  use Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI, only: [checkbox_class: 0, delimited_count: 1, input_class: 0]

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Directory
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.UserHTML

  # The work line every listing row shows, at the width the letter pages use.
  # A plain function rather than an assign: it is a constant, and a constant in
  # the socket is a change-tracked value that can never change.
  @work_string_length 60
  defp work_string_length, do: @work_string_length

  @impl true
  def mount(_params, session, socket) do
    socket
    |> InitAssigns.assign_embedded(session)
    |> assign(:connected?, connected?(socket))
    |> apply_search(session, Directory.results_limit(session["show"]))
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("search", params, socket) do
    # A changed query — or a changed field set — is a different search, so the
    # revealed bite starts over rather than carrying the last one's depth.
    {:noreply, apply_search(socket, params, Directory.results_step())}
  end

  def handle_event("show-more", _params, socket) do
    %{q: q, fields: fields, limit: limit} = socket.assigns
    params = %{"q" => q, "fields" => fields}

    # Re-running the whole search rather than fetching only the next bite: it
    # is one indexed query either way, the ceiling bounds how often it can
    # happen, and appending would mean merging the two per-row maps and
    # rebuilding both on a rejoin — three states to keep in step for work the
    # database does in about a millisecond.
    {:noreply, apply_search(socket, params, limit + Directory.results_step())}
  end

  # One place computes everything a query implies, so a `?q=` mount, a socket
  # rejoin, a keystroke and a "show more" can never disagree about the answer.
  # `params` is string-keyed either way: the controller hands the mount session
  # the form's own keys, so the two entry points differ only in the limit.
  defp apply_search(socket, params, limit) do
    q = params["q"] || ""
    fields = Directory.parse_search_fields(params["fields"])
    limit = Directory.results_limit(limit)
    results = Directory.search(q, fields, limit)
    users = (results && results.users) || []

    socket
    |> assign(:q, q)
    |> assign(:fields, fields)
    |> assign(:limit, limit)
    |> assign(:results, results)
    # The two page-wide maps every row reads, one query each, so a result list
    # never queries per row (`UserHTML.card_list`'s contract).
    |> assign(:work_info_by_id, UserHelpers.work_information_map(users, work_string_length()))
    |> assign(:following_by_id, UserHelpers.following_map(socket.assigns.current_user, users))
  end

  # Whether the list is cut short, and whether the cut can still be lifted.
  # Two names for one comparison, so the "show more" control and the
  # narrow-your-search hint read as the two sides they are instead of as a
  # condition and its double negative.
  defp truncated?(%{users: users, total: total}), do: length(users) < total

  defp more?(results, limit),
    do: truncated?(results) and limit < Directory.results_ceiling()

  defp more_path(q, fields, limit) do
    params = %{"q" => q, "fields" => fields, "show" => limit + Directory.results_step()}
    ~p"/system/members?#{params}"
  end

  defp field_label(:first_name), do: gettext("First name")
  defp field_label(:last_name), do: gettext("Last name")
  defp field_label(:username), do: gettext("Username")

  @impl true
  def render(assigns) do
    ~H"""
    <div id="directory-search" class="card-list">
      <section class="card">
        <h2>{gettext("Find a member")}</h2>

        <%!-- A real GET form, not just a phx-change box: Enter (and a browser
        with no JavaScript) submits it to this same URL, so a search is
        shareable, reloadable and survives a follow's round trip. The debounce
        sits on the text field alone, so ticking a box answers at once. --%>
        <form id="directory-search-form" action={~p"/system/members"} method="get" phx-change="search">
          <input
            type="search"
            name="q"
            value={@q}
            placeholder={gettext("Search members by name")}
            aria-label={gettext("Search members by name")}
            autocomplete="off"
            phx-debounce="250"
            class={input_class()}
          />

          <fieldset class="mt-3 flex flex-wrap items-center gap-x-5">
            <legend class="sr-only">{gettext("Which names to search")}</legend>
            <label
              :for={field <- Directory.search_fields()}
              class="inline-flex min-h-10 items-center gap-2 text-sm font-normal"
            >
              <input
                type="checkbox"
                name="fields[]"
                value={field}
                checked={field in @fields}
                data-search-field={field}
                class={checkbox_class()}
              />
              {field_label(field)}
            </label>
          </fieldset>

          <%!-- The no-JS submit. With a socket it is redundant (every change
          already answers), so it is hidden from sight and from the reading
          order rather than rendered twice or left out of the markup. --%>
          <noscript>
            <button type="submit" class="button">{gettext("Search")}</button>
          </noscript>
        </form>

        <p :if={is_nil(@results) and String.trim(@q) != ""} id="directory-search-hint" class="card__empty">
          {gettext("Results appear once you have typed at least %{count} letters.",
            count: Directory.min_query_chars()
          )}
        </p>
      </section>

      <section :if={@results} class="card" id="directory-search-results">
        <%= if @results.total == 0 do %>
          <p id="directory-search-empty" class="card__empty">
            {gettext("No members found for \"%{query}\".", query: @q)}
          </p>
        <% else %>
          <%!-- The count comes first: it is the answer to "did I spell it
          right", and it is the whole reason a large result set does not need a
          pager to be understood. --%>
          <p id="directory-search-count">
            <%= if truncated?(@results) do %>
              {gettext("Showing %{shown} of %{total} members.",
                shown: delimited_count(length(@results.users)),
                total: delimited_count(@results.total)
              )}
            <% else %>
              {ngettext("One member found.", "%{formatted} members found.", @results.total,
                formatted: delimited_count(@results.total)
              )}
            <% end %>
          </p>

          <UserHTML.card_list
            users={@results.users}
            current_user={@current_user}
            current_user_id={@current_user_id}
            filed_names={true}
            work_string_length={work_string_length()}
            work_info_by_id={@work_info_by_id}
            tags_by_id={nil}
            following_by_id={@following_by_id}
          />

          <%!-- Reveal the next bite: a phx-click once the socket carries it, a
          plain `?show=` link until then, so the control is never a button that
          does nothing. One label for both, or a wording change has to be made
          twice. --%>
          <% more_label = gettext("Show %{count} more", count: Directory.results_step()) %>
          <p :if={more?(@results, @limit)} class="text-center">
            <button
              :if={@connected?}
              type="button"
              id="directory-search-more"
              phx-click="show-more"
              class="button button--secondary"
            >
              {more_label}
            </button>
            <a
              :if={!@connected?}
              id="directory-search-more-link"
              href={more_path(@q, @fields, @limit)}
              class="button button--secondary"
            >
              {more_label}
            </a>
          </p>

          <%!-- Cut short and no further to go: at the ceiling the answer is
          another letter in the box, so say that rather than nothing. --%>
          <p
            :if={truncated?(@results) and not more?(@results, @limit)}
            id="directory-search-narrow"
            class="card__empty"
          >
            {gettext("That is as far as this list goes. Type more of the name to narrow it down.")}
          </p>
        <% end %>
      </section>
    </div>
    """
  end
end
